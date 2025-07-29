module panana::market {
    use std::bcs;
    use std::option;
    use std::option::Option;
    use std::signer;
    use std::string::{String};
    use aptos_std::math64;
    use aptos_std::simple_map;
    use aptos_std::smart_table;
    use aptos_std::smart_table::SmartTable;
    use aptos_std::type_info::account_address;
    use aptos_framework::aggregator_v2;
    use aptos_framework::aptos_account;
    use aptos_framework::dispatchable_fungible_asset;
    use aptos_framework::event;
    use aptos_framework::fungible_asset;
    use aptos_framework::fungible_asset::{FungibleAsset, Metadata, MintRef, BurnRef, amount, FungibleStore };
    use aptos_framework::object;
    use aptos_framework::object::{Object, ExtendRef, address_from_extend_ref, object_address, address_to_object };
    use aptos_framework::primary_fungible_store;
    use aptos_framework::timestamp;
    use panana::constants;
    use panana::config;
    use panana::cpmm::{LiquidityPool, available_tokens};
    use panana::cpmm_utils::to_hex;
    use panana::resource_utils;
    use panana::resource_utils::{create_token};
    use panana::cpmm_utils;
    use panana::cpmm;

    // Error code if the user is not authorized to perform an action (i.e. only admin)
    const E_UNAUTHORIZED: u64 = 1;
    // The operation a user called cannot be performed in the current market state
    const E_INVALID_MARKET_STATE: u64 = 2;
    // The action would result in too little liquidity in the market
    const E_MIN_LIQUIDITY_REQUIRED: u64 = 3;
    // The provided amount is insufficient (i.e. buy/sell 0 shares)
    const E_INVALID_AMOUNT: u64 = 4;
    // Operation cannot be performed because the market is frozen to prevent new transactions
    const E_FROZEN: u64 = 5;
    // The operation exceedes the provided slippage limit
    const E_SLIPPAGE: u64 = 6;
    // The outcome is invalid / no yes- or no-token
    const E_INVALID_OUTCOME: u64 = 7;
    // Collateral is missing to fully payout users.
    const E_COLLATERAL_MISSING: u64 = 8;
    // The provided resolution timestamp is invalid.
    const E_INVALID_RESOLUTION_TIMESTAMP: u64 = 9;

    // Denominator for all fees, allows for percentiles with 2 decimals (i.e. 2,45% = 245 of 10_000)
    const FEE_DENOMINATOR: u64 = 10_000;

    // Prefixes for the market's assets
    const ASSET_YES_PREFIX: vector<u8> = b"YES-";
    const ASSET_NO_PREFIX: vector<u8> = b"NO-";
    const ASSET_LP_PREFIX: vector<u8> = b"LP-";
    const ASSET_LPS_PREFIX: vector<u8> = b"LPS-";

    /// Event whenever a market was updated
    #[event]
    struct MarketUpdatedEvent has store, drop {
        market_obj: Object<Market>,
    }

    /// Event whenever a new market was created
    #[event]
    struct MarketCreatedEvent has store, drop {
        market_obj: Object<Market>,
    }

    /// Event whenever a buy or sell order happens
    #[event]
    enum BuySellEvent has store, drop {
        V1 {
            user: address,
            is_buy: bool,
            is_yes: bool,
            price_before: u64,
            price_after: u64,
            total_in_amount: u64,
            market_fee: u64,
            lp_fee: u64,
            creator_fee: u64,
            out_amount: u64,
            market_obj: Object<Market>,
            timestamp: u64,
        }
    }

    /// Structure to track a LP's share in a market.
    struct LpBuyIn has store, drop {
        /// Describes how much one unit of provided LP was worth at the time of provisioning
        fee_per_liquidity: u64,
        /// Total amount of provided synthetic liquidity
        total_undercollaterized: u64,
        /// Total amount of provided real liquidity
        total_fully_collaterized: u64,
    }

    /// Structure to track a User's total buy in for P&L and fee calculation.
    struct UserBuyIn has store, drop {
        /// Describes how much a user paid for all yes shares
        paid_per_yes_share: u64,
        /// Describes how much a user paid for all no shares
        paid_per_no_share: u64,
    }

    /// Outcome contains the winning outcome token and the timestamp at which the outcome was set.
    struct Outcome has store, drop {
        outcome: Object<Metadata>,
        resolution_timestamp: u64,
    }

    /// Resolution tracks the resolution status of a market.
    /// A resolution can be resolved to true or false,
    /// challenged, challenged with a final outcome (true/false),
    /// or dissolved (no outcome possible).
    struct Resolution has store {
        // If there is no outcome, the market was dissolved.
        outcome: Option<Outcome>,
        // Is some if the market is challenged
        challenged_by: Option<address>,
        // Final outcome after challenging
        challenged_outcome: Option<Outcome>,
        // The amount of shares that are locked within the cpmm at time of resolution
        cpmm_yes: u64,
        cpmm_no: u64,
    }

    /// Market entity
    enum Market has key, store {
        V1 {
            // The market creator; is set at market creation and cannot be changed
            creator: address,

            // Variables to manage the Yes Token
            yes_token: Object<Metadata>,
            yes_mint_ref: MintRef,
            yes_burn_ref: BurnRef,

            // Variables to manage the No Token
            no_token: Object<Metadata>,
            no_mint_ref: MintRef,
            no_burn_ref: BurnRef,

            // The liquidity pool used by the cpmm
            pool: Object<LiquidityPool>,

            // A list of all liquidity providers and their provided data
            lp_buyin: SmartTable<address, LpBuyIn>,
            // A list of all weighted user buyins, used to calculate P&L
            user_buyin: SmartTable<address, UserBuyIn>,
            // Liquidity accumulator describes the accumulated fee per provided liquidity unit
            acc_fee_per_liquidity: aggregator_v2::Aggregator<u64>,
            // The total amount of liquidity provided to this market
            total_lp_liq: u64,

            // Markets need at least this amount of liquidity to be active
            min_liq_required: u64,
            // Set to true if a market reaches min_liq_required for the first time; is never set to false again.
            liquidity_fully_funded: bool,

            // Numerators for different kind of buy fees (buy)
            buy_market_fee_numerator: u64,
            buy_lp_fee_numerator: u64,
            buy_creator_fee_numerator: u64,

            // Numerators for different kind of sell fees
            sell_market_fee_numerator: u64,
            sell_lp_fee_numerator: u64,
            sell_creator_fee_numerator: u64,

            // Fee stores; all fees will be sent to their corresponding stores
            market_fee_store: Object<FungibleStore>,
            creator_fee_store: Object<FungibleStore>,
            lp_fee_store: Object<FungibleStore>,

            // Market details
            description: String,
            question: String,
            rules: String,
            resolution_sources: vector<String>,

            // Timestamp of the estimated time at which this market can be resolved
            estimated_resolution: u64,

            // Type of tokens used to buy shares
            vault_type: Object<Metadata>,

            // Details about the resolution
            resolution: Option<Resolution>,

            // Duration in Secs this market can be challenged
            challenge_duration_sec: u64,
            // Users need to pay challenge_costs of vault_type assets to challenge this market
            challenge_costs: u64,

            // Reference to manage child objects
            extend_ref: ExtendRef,

            // Track the volume of this market
            volume: aggregator_v2::Aggregator<u64>,

            // Freeze a single market to prevent market interactions
            is_frozen: bool,
            // If true, all selling fee's are alrady deduced after resolution
            is_final_fee_collected: bool,
        }
    }

    /// Global state for all markets, initialized on module creation
    enum MarketGlobalState has key {
        V1 {
            // Incrementing number for each market; max number of markets that exist
            cur_market_num: u64,
            // Global reference to manage ressources
            extend_ref: ExtendRef,
        }
    }

    /// Initialize the module's global state
    fun init_module(account: &signer) {
        let constructor_ref = object::create_object(signer::address_of(account));
        let extend_ref = object::generate_extend_ref(&constructor_ref);

        move_to(account, MarketGlobalState::V1 {
            cur_market_num: 0,
            extend_ref,
        });
    }

    /// Create a new market. Everyone can create a new market. Undercollaterized markets can only be created by admin.
    /// Undercollaterized markets need to be re-collaterized after resolution in order to pay everyone out.
    /// Thus, users can only create fully collaterized markets, which do not need to be re-collaterized again.
    public entry fun create_market(
        account: &signer,
        vault_type: Object<Metadata>,
        question: String,
        description: String,
        rules: String,
        resolution_sources: vector<String>,
        estimated_resolution: u64,
        min_liq_required: u64,
        initial_liquidity: u64,
        buy_market_fee_numerator: u64,
        buy_creator_fee_numerator: u64,
        buy_lp_fee_numerator: u64,
        sell_market_fee_numerator: u64,
        sell_creator_fee_numerator: u64,
        sell_lp_fee_numerator: u64,
        is_frozen: bool,
        is_undercollaterized: bool,
    ) acquires MarketGlobalState {
        // Undercollateralized markets can only be created by admins
        assert!(!is_undercollaterized || signer::address_of(account) == config::admin(), E_UNAUTHORIZED);
        assert!(buy_market_fee_numerator + buy_lp_fee_numerator + buy_creator_fee_numerator <= FEE_DENOMINATOR, E_INVALID_AMOUNT);
        assert!(sell_market_fee_numerator + sell_lp_fee_numerator + sell_creator_fee_numerator <= FEE_DENOMINATOR, E_INVALID_AMOUNT);
        assert!(estimated_resolution >= timestamp::now_seconds(), E_INVALID_RESOLUTION_TIMESTAMP);

        let global_state = borrow_global_mut<MarketGlobalState>(@panana);

        // ensure minimun liquidity in market
        let global_min_required_liq = config::default_min_liquidity_required(vault_type);
        assert!(min_liq_required >= global_min_required_liq, E_MIN_LIQUIDITY_REQUIRED);

        let market_id_as_hex = to_hex(global_state.cur_market_num);

        // Generate all token symbols
        let yes_symbol = ASSET_YES_PREFIX;
        let no_symbol = ASSET_NO_PREFIX;
        let lp_symbol = ASSET_LP_PREFIX;
        let lps_symbol = ASSET_LPS_PREFIX;
        yes_symbol.append(market_id_as_hex);
        no_symbol.append(market_id_as_hex);
        lp_symbol.append(market_id_as_hex);
        lps_symbol.append(market_id_as_hex);

        let (yes_mint_ref, yes_burn_ref, yes_token) = create_token(&global_state.extend_ref, yes_symbol);
        let (no_mint_ref, no_burn_ref, no_token) = create_token(&global_state.extend_ref, no_symbol);

        // Mint initial liquidity (X$ input equals X tokens for each side since each side is exactly 0.5$)
        let initial_yes_tokens = fungible_asset::mint(&yes_mint_ref, initial_liquidity);
        let initial_no_tokens = fungible_asset::mint(&no_mint_ref, initial_liquidity);

        // Create liquidity pool for swapping and deposit liquidity tokens to creator
        let (lp_tokens, pool) = cpmm::create_liquidity_pool(
            initial_yes_tokens,
            initial_no_tokens,
            lp_symbol,
            lps_symbol,
            is_undercollaterized
        );
        let caller = signer::address_of(account);
        aptos_account::deposit_fungible_assets(caller, lp_tokens);

        let (market_signer, market_extend_ref, market_address) = resource_utils::create_seed_object(
            &object::generate_signer_for_extending(&global_state.extend_ref),
            bcs::to_bytes(&global_state.cur_market_num)
        );

        // Increment global state to add one more market
        global_state.cur_market_num = global_state.cur_market_num + 1;

        // Store liquidity provisioning information for proportional lp fee calculation depending on provided liquidity later
        let lp_buyin = smart_table::new<address, LpBuyIn>();
        let total_undercollaterized = if (is_undercollaterized) initial_liquidity else 0;
        let total_fully_collaterized = if (is_undercollaterized) 0 else initial_liquidity;
        lp_buyin.add(caller, LpBuyIn { total_undercollaterized, total_fully_collaterized, fee_per_liquidity: 0 });

        // Create fee stores for all fees
        let (market_fee_store, _, _) = resource_utils::create_token_store(
            address_from_extend_ref(&market_extend_ref),
            vault_type
        );
        let (creator_fee_store, _, _) = resource_utils::create_token_store(
            address_from_extend_ref(&market_extend_ref),
            vault_type
        );
        let (lp_fee_store, _, _) = resource_utils::create_token_store(
            address_from_extend_ref(&market_extend_ref),
            vault_type
        );

        // Market creation may occure some fees. Collect fees for non-admin users.
        let market_creation_cost = config::market_creation_costs(vault_type);
        if (config::admin() != signer::address_of(account) && market_creation_cost > 0) {
            primary_fungible_store::transfer(account, vault_type, config::market_fee_address(), market_creation_cost);
        };

        // Create market
        let market = Market::V1 {
            creator: caller,
            no_token,
            no_burn_ref,
            no_mint_ref,
            yes_token,
            yes_mint_ref,
            yes_burn_ref,
            pool,
            acc_fee_per_liquidity: aggregator_v2::create_unbounded_aggregator_with_value(0),
            total_lp_liq: initial_liquidity,
            lp_buyin,
            user_buyin: smart_table::new(),
            min_liq_required,
            liquidity_fully_funded: initial_liquidity >= min_liq_required,
            description,
            question,
            rules,
            resolution_sources,
            estimated_resolution,
            market_fee_store,
            creator_fee_store,
            lp_fee_store,
            buy_market_fee_numerator,
            buy_lp_fee_numerator,
            buy_creator_fee_numerator,
            sell_market_fee_numerator,
            sell_lp_fee_numerator,
            sell_creator_fee_numerator,
            vault_type,
            resolution: option::none(),
            volume: aggregator_v2::create_unbounded_aggregator_with_value(0),
            challenge_duration_sec: config::default_challenge_duration_sec(),
            challenge_costs: config::default_challenge_costs(vault_type),
            extend_ref: market_extend_ref,
            is_frozen,
            is_final_fee_collected: false,
        };

        // Only fully collaterized markets need to be funded
        if (!is_undercollaterized) {
            primary_fungible_store::transfer(account, vault_type, signer::address_of(&market_signer), initial_liquidity);
        };

        move_to(&market_signer, market);
        event::emit(MarketCreatedEvent { market_obj: address_to_object<Market>(market_address) });
    }


    /// Update a market. Only admins are allowed to do so. Selling fees cannot be changed after final fee collection.
    public entry fun update_market(
        account: &signer,
        market_obj: Object<Market>,
        question: Option<String>,
        description: Option<String>,
        rules: Option<String>,
        resolution_sources: Option<vector<String>>,
        min_liq_required: Option<u64>,
        estimated_resolution: Option<u64>,
        buy_market_fee_numerator: Option<u64>,
        buy_lp_fee_numerator: Option<u64>,
        buy_creator_fee_numerator: Option<u64>,
        sell_market_fee_numerator: Option<u64>,
        sell_lp_fee_numerator: Option<u64>,
        sell_creator_fee_numerator: Option<u64>,
        is_frozen: Option<bool>,
    ) acquires Market {
        config::assert_admin(account);

        let market = borrow_global_mut<Market>(object::object_address(&market_obj));

        market.question = *question.borrow_with_default(&market.question);
        market.description = *description.borrow_with_default(&market.description);
        market.rules = *rules.borrow_with_default(&market.rules);
        market.resolution_sources = *resolution_sources.borrow_with_default(&market.resolution_sources);
        assert!(market.resolution_sources.length() > 0, E_INVALID_AMOUNT);
        market.estimated_resolution = *estimated_resolution.borrow_with_default(&market.estimated_resolution);
        market.buy_market_fee_numerator = *buy_market_fee_numerator.borrow_with_default(
            &market.buy_market_fee_numerator
        );
        market.buy_creator_fee_numerator = *buy_creator_fee_numerator.borrow_with_default(
            &market.buy_creator_fee_numerator
        );
        market.buy_lp_fee_numerator = *buy_lp_fee_numerator.borrow_with_default(&market.buy_lp_fee_numerator);
        assert!(market.buy_market_fee_numerator + market.buy_lp_fee_numerator + market.buy_creator_fee_numerator <= FEE_DENOMINATOR, E_INVALID_AMOUNT);

        market.min_liq_required = *min_liq_required.borrow_with_default(&market.min_liq_required);
        assert!(market.min_liq_required >= config::default_min_liquidity_required(market.vault_type), E_INVALID_AMOUNT);

        /// If the final fee was collected, changing the selling fees is no longer possible because this could result
        /// in insufficient or excess vault balance.
        if (!market.is_final_fee_collected) {
            market.sell_market_fee_numerator = *sell_market_fee_numerator.borrow_with_default(
                &market.sell_market_fee_numerator
            );
            market.sell_creator_fee_numerator = *sell_creator_fee_numerator.borrow_with_default(
                &market.sell_creator_fee_numerator
            );
            market.sell_lp_fee_numerator = *sell_lp_fee_numerator.borrow_with_default(&market.sell_lp_fee_numerator);
            assert!(market.sell_market_fee_numerator + market.sell_lp_fee_numerator + market.sell_creator_fee_numerator <= FEE_DENOMINATOR, E_INVALID_AMOUNT);
        };

        market.is_frozen = *is_frozen.borrow_with_default(&market.is_frozen);

        event::emit(MarketUpdatedEvent { market_obj });
    }

    /// Buy shares lets users buy shares from a market. Users can prevent high slippage by setting the slippage_min_out
    /// parameter. Buying is only possible when the market's initial liquidity was fully funded and the market is not
    /// finally resolved yet.
    public entry fun buy_shares(
        account: &signer,
        market_obj: Object<Market>,
        is_yes: bool,
        amount: u64,
        slippage_min_out: u64,
    ) acquires Market {
        assert_unfrozen(market_obj);
        assert!(amount > 0, E_INVALID_AMOUNT);

        let market = borrow_global_mut<Market>(object::object_address(&market_obj));

        // Not fully funded case
        assert!(market.liquidity_fully_funded, E_INVALID_MARKET_STATE);

        let (is_final, _result) = is_finalized_with_result_impl(market);

        // Final Resolution case
        assert!(!is_final, E_INVALID_MARKET_STATE);

        let (price_yes_before, price_no_before) = prices_impl(market);

        // Running market case
        // Withdraw user tokens and extract fee before depositing it to the vault
        let user_tokens = primary_fungible_store::withdraw(account, market.vault_type, amount);
        let (user_tokens, market_fee, creator_fee, lp_fee) = extract_fee(user_tokens, market, true);
        let buy_amount = fungible_asset::amount(&user_tokens);
        primary_fungible_store::deposit(object::object_address(&market_obj), user_tokens);

        let (mint_output, mint_input) = if (is_yes) {
            (&market.yes_mint_ref, &market.no_mint_ref)
        } else {
            (&market.no_mint_ref, &market.yes_mint_ref)
        };

        // We mint X tokens for each side because price(1 No) + price(1 Yes) = 1 input token.
        let output_tokens = fungible_asset::mint(mint_output, buy_amount);
        let input_tokens = fungible_asset::mint(mint_input, buy_amount);
        // Swap tokens the user don't want to get more tokens the user want
        let swapped_tokens = cpmm::swap(market.pool, input_tokens, 0);

        // merge them all
        fungible_asset::merge(&mut output_tokens, swapped_tokens);

        // enforce slippage and deposit
        let out_amount = fungible_asset::amount(&output_tokens);
        assert!(out_amount >= slippage_min_out, E_SLIPPAGE);

        // Update paid per share price for user to calculate P&L and calculate fee on profits
        update_user_buyin(signer::address_of(account), market, amount, constants::price_scaling_factor(), out_amount, is_yes);

        aptos_account::deposit_fungible_assets(signer::address_of(account), output_tokens);

        // Add the purchasing amount to the market's volume
        aggregator_v2::add(&mut market.volume, amount);

        let (price_yes_after, price_no_after) = prices_impl(market);
        event::emit(BuySellEvent::V1 {
            user: signer::address_of(account),
            is_buy: true,
            is_yes,
            price_before: if(is_yes) price_yes_before else price_no_before,
            price_after: if(is_yes) price_yes_after else price_no_after,
            out_amount,
            total_in_amount: amount,
            market_fee,
            lp_fee,
            creator_fee,
            timestamp: timestamp::now_seconds(),
            market_obj,
        });
    }

    /// Sell shares of the provided type. Prevent high slippage through the slippage_min_out parameter.
    public entry fun sell_shares(
        account: &signer,
        market_obj: Object<Market>,
        is_yes: bool,
        amount: u64,
        slippage_min_out: u64,
    ) acquires Market {
        // Basic validations
        assert!(amount > 0, E_INVALID_AMOUNT);
        assert_unfrozen(market_obj);
        let addr = object::object_address(&market_obj);
        let market = borrow_global_mut<Market>(addr);

        // Calls only possible if market is fully funded and open or finalized
        let (is_final, result_opt) = is_finalized_with_result_impl(market);
        assert!(market.liquidity_fully_funded, E_INVALID_MARKET_STATE);

        // Store price before selling shares for event emission
        let (price_yes_before, price_no_before) = prices_impl(market);

        // Always collect any final fees first
        collect_market_finalized_fees(addr, market);

        // Withdraw the users tokens
        let (sell_token, sell_burn_ref) = if (is_yes) {
            (market.yes_token, &market.yes_burn_ref)
        } else {
            (market.no_token, &market.no_burn_ref)
        };
        let user_tokens = primary_fungible_store::withdraw(account, sell_token, amount);

        // RESOLVED path
        let (out_amount, market_fee, creator_fee, lp_fee) = if (is_final) {
            let (yes_price, no_price) = prices_impl(market);
            let price = if (is_yes) { yes_price } else { no_price };
            let payout = math64::mul_div(amount, price, constants::price_scaling_factor());

            // compute fees on the payout
            let (m_fee, c_fee, l_fee) = calculate_fee(
                market.sell_market_fee_numerator,
                market.sell_creator_fee_numerator,
                market.sell_lp_fee_numerator,
                payout
            );
            // fees are already deduced by collect_market_finalized_fees, so fees are not paid out to the user
            let net = payout - m_fee - c_fee - l_fee;

            // if dissolved or winner shares selling -> pay out from vault
            let should_payout = result_opt.is_none()
                || (is_yes && *result_opt.borrow() == market.yes_token
                || (!is_yes && (*result_opt.borrow() == market.no_token)));
            if (should_payout) {
                aptos_account::transfer_fungible_assets(market_signer(market), market.vault_type, signer::address_of(account), net);
            };

            // burn whatever tokens the user sent (winning or losing)
            fungible_asset::burn(sell_burn_ref, user_tokens);

            (if (should_payout) net else 0, m_fee, c_fee, l_fee)
        } else {
            // RUNNING-MARKET path
            let avail_tokens = cpmm::available_tokens(market.pool);
            let in_vault = *avail_tokens.borrow(if (is_yes) &market.yes_token else &market.no_token);
            let out_vault = *avail_tokens.borrow(if (is_yes) &market.no_token else &market.yes_token);
            let payout = simulate_sell_shares(in_vault, out_vault, amount);

            // split out the portion to swap vs. to burn
            let to_swap = fungible_asset::extract(&mut user_tokens, amount - payout);
            fungible_asset::burn(sell_burn_ref, user_tokens);

            // swap via the pool, then burn the opposite tokens from the swap
            let swapped = cpmm::swap(market.pool, to_swap, 0);
            let opposite_burn = if (sell_token == market.yes_token) &market.no_burn_ref else &market.yes_burn_ref;
            fungible_asset::burn(opposite_burn, swapped);

            // withdraw from vault, deduct fees, check slippage, deposit to user
            let vault_store = primary_fungible_store::ensure_primary_store_exists(addr, market.vault_type);
            let payout_tokens = dispatchable_fungible_asset::withdraw(
                market_signer(market),
                vault_store,
                payout
            );
            let (payout_tokens, market_fee, creator_fee, lp_fee) = extract_fee(payout_tokens, market, false);
            let payout_amount = fungible_asset::amount(&payout_tokens);
            assert!(payout_amount >= slippage_min_out, E_SLIPPAGE);
            primary_fungible_store::deposit(signer::address_of(account), payout_tokens);

            (payout_amount, market_fee, creator_fee, lp_fee)
        };

        // Add the selling amount to the market's volume
        aggregator_v2::add(&mut market.volume, out_amount + market_fee + lp_fee + creator_fee);

        // emit price-changed
        let (price_yes_after, price_no_after) = prices_impl(market);
        event::emit(BuySellEvent::V1 {
            user: signer::address_of(account),
            is_buy: false,
            is_yes,
            price_before: if(is_yes) price_yes_before else price_no_before,
            price_after: if(is_yes) price_yes_after else price_no_after,
            out_amount,
            total_in_amount: amount,
            market_fee,
            lp_fee,
            creator_fee,
            timestamp: timestamp::now_seconds(),
            market_obj,
        });
    }

    /// Resolve a running market. This function can be used to resolve a market for the first time, as well as
    /// after challenging the outcome. After chellinging, this function can only be called by the oracle.
    public entry fun resolve_market(account: &signer, market_obj: Object<Market>, outcome: Object<Metadata>) acquires Market {
        let market = borrow_global_mut<Market>(object::object_address(&market_obj));
        let account_address = signer::address_of(account);

        if (market.resolution.is_none()) {
            // Handle the market's first resolution
            assert!(account_address == config::admin() || account_address == config::resolver(), E_UNAUTHORIZED);


            let available_tokens = cpmm::available_tokens(market.pool);
            let cpmm_yes = *available_tokens.borrow(&market.yes_token);
            let cpmm_no = *available_tokens.borrow(&market.no_token);

            // Set resolution outcome and amount of shares at resolution to calculate the fee payout after resolution
            // and allow for re-calculation of prices at time of resolution. If all liquidity is later withdrawm from
            // the market, the shares of one side of the cpmm could go to 0, making a price calculation impossible
            // (division by zero).
            market.resolution.fill(Resolution {
                outcome: option::some(Outcome {
                    outcome,
                    resolution_timestamp: timestamp::now_seconds(),
                }),
                challenged_by: option::none(),
                challenged_outcome: option::none(),
                cpmm_yes,
                cpmm_no,
            });
        } else {
            // Handle the oracle resolution. Market must be challenged for this to work.
            assert!(signer::address_of(account) == config::resolution_oracle(), E_UNAUTHORIZED);

            let resolution = market.resolution.borrow_mut();
            assert!(
                resolution.challenged_by.is_some(),
                E_INVALID_MARKET_STATE
            ); // market needs to be challenged for oracle to have a say in the outcome

            resolution.challenged_outcome.fill(Outcome {
                outcome,
                resolution_timestamp: timestamp::now_seconds(),
            });

            let challenger = resolution.challenged_by.borrow();
            // If the outcome was decided against the initial outcome, the challenger was right.
            // Thus, we return the stake to the challenger. Otherwise, we keep it as market fees.
            if (outcome != resolution.outcome.borrow().outcome) {
                dispatchable_fungible_asset::transfer(
                    market_signer(market),
                    market.market_fee_store,
                    primary_fungible_store::primary_store(*challenger, market.vault_type),
                    market.challenge_costs,
                );
            }
        };
        event::emit(MarketUpdatedEvent { market_obj });
    }

    /// A market can be challenged by everyone as long as the market has been initially resolved and the challenge period
    /// has not ended. To challenge a market, a user needs to pay challenge costs.
    /// The challenge costs are part of the market fees and are manually returned to the challenging user if the
    /// challenge was successfull.
    public entry fun challenge_market(account: &signer, market_obj: Object<Market>) acquires Market {
        let market = borrow_global_mut<Market>(object::object_address(&market_obj));
        let (is_final, _) = is_finalized_with_result_impl(market);
        assert!(!is_final && market.resolution.is_some(), E_INVALID_MARKET_STATE);

        let resolution = market.resolution.borrow_mut();
        // Ensure market is initially resolved but not yet challenged
        assert!(resolution.outcome.is_some() && resolution.challenged_by.is_none(), E_INVALID_MARKET_STATE);

        dispatchable_fungible_asset::transfer(account, primary_fungible_store::primary_store(
            signer::address_of(account),
            market.vault_type
        ), market.market_fee_store, market.challenge_costs);

        resolution.challenged_by.fill(signer::address_of(account));
        event::emit(MarketUpdatedEvent { market_obj });
    }

    /// Use this function to transfer the market and creator fees from their stores to the corresponding account.
    /// LP fees are not transferred in this function, but rewarded to the LP upon LP withdrawal.
    public entry fun collect_fees(account: &signer, market_obj: Object<Market>) acquires Market {
        config::assert_admin(account);
        let market = borrow_global_mut<Market>(object::object_address(&market_obj));

        // Ensure that if the market was finalized, remaining fees are deduced before payout.
        collect_market_finalized_fees(object_address(&market_obj), market);

        // Only collect market and creator fees; LP fees are collected upon LP withdrawal
        let market_fees = dispatchable_fungible_asset::derived_balance(market.market_fee_store);
        let creator_fees = dispatchable_fungible_asset::derived_balance(market.creator_fee_store);

        // Ensure that if the market was challenged and not yet decided, the challenge fees remain in the vault.
        if (market.resolution.is_some() && market.resolution.borrow().challenged_by.is_some() && market.resolution.borrow().challenged_outcome.is_none()) {
            market_fees = market_fees - market.challenge_costs;
        };

        dispatchable_fungible_asset::deposit(
            primary_fungible_store::ensure_primary_store_exists(config::market_fee_address(), market.vault_type),
            dispatchable_fungible_asset::withdraw(market_signer(market), market.market_fee_store, market_fees)
        );
        dispatchable_fungible_asset::deposit(
            primary_fungible_store::ensure_primary_store_exists(market.creator, market.vault_type),
            dispatchable_fungible_asset::withdraw(market_signer(market), market.creator_fee_store, creator_fees),
        );
    }

    /// Dissolving a market means the outcome could not be determined.
    /// A market can be dissolved by an admin and the resolver instead of an initial resolution.
    /// It can also be dissolved by the resolution oracle if the market was challenged.
    /// This is an alternative option to resolving a market.
    public entry fun dissolve_market(account: &signer, market_obj: Object<Market>) acquires Market {
        let market = borrow_global_mut<Market>(object::object_address(&market_obj));
        let account_address = signer::address_of(account);

        let is_admin_or_resolver_on_initial_resolution = market.resolution.is_none() && (config::admin() == account_address || config::resolver() == account_address);
        let is_challenge_pending = market.resolution.is_some() && market.resolution.borrow().challenged_by.is_some() && market.resolution.borrow().challenged_outcome.is_none();
        let is_oracle_on_challenged_open_market = is_challenge_pending && config::resolution_oracle() == account_address;
        assert!(is_admin_or_resolver_on_initial_resolution || is_oracle_on_challenged_open_market, E_UNAUTHORIZED);

        let available_tokens = cpmm::available_tokens(market.pool);
        let cpmm_yes = *available_tokens.borrow(&market.yes_token);
        let cpmm_no = *available_tokens.borrow(&market.no_token);

        if (market.resolution.is_some()) {
            let resolution = market.resolution.borrow_mut();
            // In case of dissolving after initial resolution, only the outcome is removed
            // to keep other values such as challenged_by intact.
            resolution.outcome.extract();
        } else {
            market.resolution.fill(Resolution {
                outcome: option::none(),
                challenged_by: option::none(),
                challenged_outcome: option::none(),
                cpmm_yes,
                cpmm_no
            });
        };
        event::emit(MarketUpdatedEvent { market_obj });
    }

    /// Add Liquidity to the market. Liquidity can be synthetic, leading to an undercollaterized market. In such a case,
    /// no tokens are withdrawn from the caller now but selling the LPS token results in a re-collaterization of the
    /// vault. Only admin can add synthetic liquidity. LPs get LP tokens and most likely outcome shares in return.
    public entry fun add_liquidity(
        account: &signer,
        market_obj: Object<Market>,
        amount: u64,
        is_synthetic: bool,
    ) acquires Market {
        assert!(amount > 0, E_INVALID_AMOUNT);
        // Synthetic liquidity can only be added by the admin.
        assert!(!is_synthetic || signer::address_of(account) == config::admin(), E_UNAUTHORIZED);
        assert_unfrozen(market_obj);

        let market = borrow_global_mut<Market>(object::object_address(&market_obj));
        let (is_final, _) = is_finalized_with_result_impl(market);
        assert!(!is_final, E_INVALID_MARKET_STATE);

        let market_obj_address = object::object_address(&market_obj);

        // 1) Transfer collateral into the vault if needed
        let user_vault = primary_fungible_store::ensure_primary_store_exists(
            signer::address_of(account),
            market.vault_type
        );
        if (!is_synthetic) {
            let market_vault = primary_fungible_store::ensure_primary_store_exists(
                market_obj_address,
                market.vault_type
            );
            dispatchable_fungible_asset::transfer(account, user_vault, market_vault, amount);
        };

        // 2) Update total liquidity and funding flag
        let new_total = market.total_lp_liq + amount;
        market.total_lp_liq = new_total;
        if (!market.liquidity_fully_funded && new_total >= market.min_liq_required) {
            market.liquidity_fully_funded = true;
        };

        // 3) Mint matching yes/no tokens
        let (yes_tokens, no_tokens) = (
            fungible_asset::mint(&market.yes_mint_ref, amount),
            fungible_asset::mint(&market.no_mint_ref,  amount)
        );

        // 4) Track fee entitlements
        let acc_fee = aggregator_v2::read(&market.acc_fee_per_liquidity);
        let rec = market.lp_buyin.borrow_mut_with_default(
            signer::address_of(account),
            LpBuyIn { total_fully_collaterized: 0, total_undercollaterized: 0, fee_per_liquidity: acc_fee }
        );
        if (is_synthetic) {
            let prev = rec.total_undercollaterized;
            let updated = prev + amount;
            rec.total_undercollaterized = updated;
            rec.fee_per_liquidity = acc_fee - math64::mul_div(acc_fee - rec.fee_per_liquidity, prev, updated);
        } else {
            let prev = rec.total_fully_collaterized;
            let updated = prev + amount;
            rec.total_fully_collaterized = updated;
            rec.fee_per_liquidity = acc_fee - math64::mul_div(acc_fee - rec.fee_per_liquidity, prev, updated);
        };

        // 5) Add liquidity into the pool and return leftovers
        let (lp_tokens, yes_remainder, no_remainder) =
            cpmm::add_liquidity(market.pool, yes_tokens, no_tokens, is_synthetic);

        let yes_remainder_amount = fungible_asset::amount(&yes_remainder);
        let no_remainder_amount = fungible_asset::amount(&no_remainder);
        let (yes_price, no_price) = prices_impl(market);

        if (yes_remainder_amount > 0) {
            update_user_buyin(signer::address_of(account), market, amount, yes_price, yes_remainder_amount, true);
        };
        if (no_remainder_amount > 0){
            update_user_buyin(signer::address_of(account), market, amount, no_price, no_remainder_amount, false);
        };

        aptos_account::deposit_fungible_assets(signer::address_of(account), lp_tokens);
        aptos_account::deposit_fungible_assets(signer::address_of(account), yes_remainder);
        aptos_account::deposit_fungible_assets(signer::address_of(account), no_remainder);
        event::emit(MarketUpdatedEvent { market_obj });
    }

    /// Withdraw liquidity from the market by providing LP(s) tokens.
    /// If user provides LP tokens, they get vault tokens and least likely outcome shares back.
    /// If the user provides LPs tokens, they need to re-collaterize the market and only get least likely outcome shares back.
    public entry fun withdraw_liquidity(
        account: &signer,
        market_obj: Object<Market>,
        amount: u64,
        is_synthetic: bool,
    ) acquires Market {
        assert!(amount > 0, E_INVALID_AMOUNT);
        // Basic checks & setup
        assert_unfrozen(market_obj);
        let addr = object::object_address(&market_obj);
        let market = borrow_global_mut<Market>(addr);

        // If finalized, collect outstanding fees
        collect_market_finalized_fees(addr, market);

        // Calculate fee-inclusive payout and update accounting
        let acc_fee = aggregator_v2::read(&market.acc_fee_per_liquidity);
        let (fee_payout, lp_fraction) = fractional_lp_fee_payout(
            market,
            signer::address_of(account),
            amount,
            acc_fee,
            is_synthetic
        );
        market.total_lp_liq = market.total_lp_liq - lp_fraction;
        let lp_rec = market.lp_buyin.borrow_mut(signer::address_of(account));
        if (is_synthetic) {
            lp_rec.total_undercollaterized = lp_rec.total_undercollaterized - lp_fraction;
        } else {
            lp_rec.total_fully_collaterized = lp_rec.total_fully_collaterized - lp_fraction;
        };

        // Pay out fees immediately
        dispatchable_fungible_asset::transfer(
            market_signer(market),
            market.lp_fee_store,
            primary_fungible_store::ensure_primary_store_exists(
                signer::address_of(account),
                market.vault_type
            ),
            fee_payout
        );


        // Withdraw LP tokens from user
        // Determine which LP token to use
        let (is_final, result) = is_finalized_with_result_impl(market);
        let (lp_meta, lps_meta) = cpmm::lp_tokens(market.pool);
        let chosen_lp = if (is_synthetic) { lps_meta } else { lp_meta };
        let lp_tokens = primary_fungible_store::withdraw(account, chosen_lp, amount);
        let lp_value = cpmm::lp_value(market.pool, amount, result);


        let avail_tokens = cpmm::available_tokens(market.pool);
        let avail_yes_token = *avail_tokens.borrow(&market.yes_token);
        let avail_no_token = *avail_tokens.borrow(&market.no_token);
        let prev_max = math64::max(avail_yes_token, avail_no_token);

        let mint_ref = if (result.is_some() && is_final && *result.borrow() == market.yes_token) {
            &market.no_mint_ref
        } else if (result.is_some() && is_final && *result.borrow() == market.no_token) {
            &market.yes_mint_ref
        } else {
            if (avail_yes_token > avail_no_token) &market.yes_mint_ref else &market.no_mint_ref
        };


        // Remove underlying assets from the pool and burn them
        let (token_a, token_b) = cpmm::remove_liquidity(market.pool, lp_tokens);
        let a_burn_ref = if (fungible_asset::metadata_from_asset(&token_a) == market.yes_token) &market.yes_burn_ref else &market.no_burn_ref;
        let b_burn_ref = if (fungible_asset::metadata_from_asset(&token_b) == market.yes_token) &market.yes_burn_ref else &market.no_burn_ref;
        fungible_asset::burn(a_burn_ref, token_a);
        fungible_asset::burn(b_burn_ref,  token_b);

        let avail_tokens = cpmm::available_tokens(market.pool);
        let avail_yes_token = *avail_tokens.borrow(&market.yes_token);
        let avail_no_token = *avail_tokens.borrow(&market.no_token);
        let max_shares = math64::max(avail_yes_token, avail_no_token);

        // Calculate the amount of tokens the user gets in addition to the withdrawn base asset if the probability is
        // not 50/50
        if (lp_value + max_shares <= prev_max) {
            let amt = prev_max - lp_value - max_shares;
            // If the probability is 50/50, no tokens are minted and we can skip this step
            if (amt > 0) {
                let token = fungible_asset::mint(mint_ref, amt);
                let token_meta = fungible_asset::metadata_from_asset(&token);

                let (yes_price, no_price) = prices_impl(market);
                // The user did not pay anything for the shares, so the value of each individual share is the current price.
                // = N new shares for the price of N * price_per_share
                if (token_meta == market.yes_token) {
                    update_user_buyin(signer::address_of(account), market, amt, yes_price, amt, true);
                } else if (token_meta == market.no_token) {
                    update_user_buyin(signer::address_of(account), market, amt, no_price, amt, false);
                };

                primary_fungible_store::deposit(signer::address_of(account), token);
            }
        };

        // Ensure we don't break the pool if still open
        assert!(
            is_final
                || !market.liquidity_fully_funded
                || cpmm::liquidity(market.pool) >= market.min_liq_required,
            E_MIN_LIQUIDITY_REQUIRED
        );

        // Refund vault stake for non-synthetic LP
        if (!is_synthetic) {
            primary_fungible_store::transfer(
                market_signer(market),
                market.vault_type,
                signer::address_of(account),
                lp_value
            );
        } else {
            // Handle re-collateralization or excess payout based on LP share vs. value
            let diff = if (lp_fraction > lp_value) lp_fraction - lp_value else lp_value - lp_fraction;
            let (m_fee, c_fee, lp_fee) = calculate_fee(
                market.sell_market_fee_numerator,
                market.sell_creator_fee_numerator,
                market.sell_lp_fee_numerator,
                diff
            );
            let net_diff = if (is_final) diff - (m_fee + c_fee + lp_fee) else diff;

            if (lp_fraction > lp_value) {
                // LP needs to re-collateralize
                primary_fungible_store::transfer(
                    account,
                    market.vault_type,
                    object_address(&market_obj),
                    net_diff
                );
            } else {
                // LP is owed excess payout
                primary_fungible_store::transfer(
                    market_signer(market),
                    market.vault_type,
                    signer::address_of(account),
                    net_diff
                );
            }
        };
        event::emit(MarketUpdatedEvent { market_obj });
    }

    /// Update the user buyin price per share. The user buy in per share represents the avg. price the user paid for a
    /// single share.
    fun update_user_buyin(user: address, market: &mut Market, purchase_amount: u64, price: u64, new_shares: u64, is_yes: bool) {
        let user_buyin = market.user_buyin.borrow_mut_with_default(user, UserBuyIn {
            paid_per_yes_share: 0,
            paid_per_no_share: 0,
        });

        let token = if (is_yes) market.yes_token else market.no_token;

        let balance = primary_fungible_store::balance(user, token);
        let paid_for = if (is_yes) user_buyin.paid_per_yes_share else user_buyin.paid_per_no_share;
        let paid_for_all_shares = (balance as u128) * (paid_for as u128) + (purchase_amount as u128) * (price as u128);
        let total_shares = (balance as u128) + (new_shares as u128);
        // Edge case if user didn't buy any new shares (happens only if 100% fees).
        if (total_shares == 0) {
            return;
        };
        let updated_paid_per_share = ((paid_for_all_shares / total_shares) as u64);
        if (is_yes) {
            user_buyin.paid_per_yes_share = updated_paid_per_share;
        } else {
            user_buyin.paid_per_no_share = updated_paid_per_share;
        }
    }

    /// Return the prices of yes and no shares, in that order.
    #[view]
    public fun prices(market_obj: Object<Market>): (u64, u64) acquires Market {
        let market = borrow_global<Market>(object::object_address(&market_obj));
        prices_impl(market)
    }

    /// Get the cpmm share balance of the provided market
    #[view]
    public fun shares(market_obj: Object<Market>): (u64, u64) acquires Market {
        let market = borrow_global<Market>(object::object_address(&market_obj));
        let avail_tokens = cpmm::available_tokens(market.pool);
        let cpmm_yes = *avail_tokens.borrow(&market.yes_token);
        let cpmm_no = *avail_tokens.borrow(&market.no_token);
        (cpmm_yes, cpmm_no)
    }

    /// Return the market object for the provided market ID.
    #[view]
    public fun market_by_id(market_id: u64): Object<Market> acquires MarketGlobalState {
        let global_state = borrow_global<MarketGlobalState>(@panana);
        let market_owner = object::address_from_extend_ref(&global_state.extend_ref);
        let market_address = object::create_object_address(&market_owner, bcs::to_bytes(&market_id));
        object::address_to_object<Market>(market_address)
    }

    /// Return the amount of LP fees a specific address has gathered for a specific market.
    #[view]
    public fun lp_fees(market_obj: Object<Market>, lp_address: address): u64 acquires Market {
        let market = borrow_global<Market>(object::object_address(&market_obj));
        let res = market.lp_buyin.borrow_with_default(lp_address, &LpBuyIn { total_fully_collaterized: 0, total_undercollaterized: 0, fee_per_liquidity: 0 });
        let acc_fee_per_liquidity = aggregator_v2::read(&market.acc_fee_per_liquidity);
        math64::mul_div((acc_fee_per_liquidity - res.fee_per_liquidity), res.total_fully_collaterized + res.total_undercollaterized, constants::price_scaling_factor())
    }

    /// Simulate buying N shares from the given cpmm balance state. The input is given in the market's base asset.
    #[view]
    public fun simulate_buy_shares(in_vault_balance: u64, out_vault_balance: u64, buy_amount: u64): u64 {
        let (_, new_out_vault_balance) = cpmm::simulate_token_change(in_vault_balance, out_vault_balance, buy_amount);
        buy_amount + out_vault_balance - new_out_vault_balance
    }

    /// Simulate selling N shares to the given cpmm balance state. The payout is given in the base asset.
    #[view]
    public fun simulate_sell_shares(in_vault_balance: u64, out_vault_balance: u64, sell_amount: u64): u64 {
        let k = (in_vault_balance as u128) * (out_vault_balance as u128);
        let x = in_vault_balance + sell_amount;
        let y = out_vault_balance;
        let (n1, n2) = cpmm_utils::solve_quadratic_equation(x, y, k);
        // The quadratic results have been floored before
        // let payout = if (n1 != 0) n1 else if (n2 != 0) n2 else 0;
        let payout = if (n2.is_some()) math64::min(n1, *n2.borrow()) else n1;
        payout
    }

    /// Return the avg. price a user paid for a share. The result can be used to calculate P&L, profit, and fees.
    #[view]
    public fun user_buyin(market_obj: Object<Market>, user: address): (u64, u64) acquires Market {
        let market = borrow_global_mut<Market>(object_address(&market_obj));
        let res = market.user_buyin.borrow_with_default(user, &UserBuyIn {
            paid_per_yes_share: 0,
            paid_per_no_share: 0
        });
        (res.paid_per_yes_share, res.paid_per_no_share)
    }

    /// Make sure the provided market is not frozen
    fun assert_unfrozen(market_obj: Object<Market>) acquires Market {
        assert!(!config::is_frozen(), E_FROZEN);
        let market = borrow_global<Market>(object::object_address(&market_obj));
        assert!(!market.is_frozen, E_FROZEN);
    }

    /// Check if the market resolution is final.
    /// If the outcome could still be challenged, the resolution is not final. Returns a boolean if the resolution is
    /// final, and an option with the result. If the returned bool is true and the option is empty, the market was dissolved.
    fun is_finalized_with_result_impl(market: &Market): (bool, Option<Object<Metadata>>) {
        // market still running
        if (market.resolution.is_none()) {
            return (false, option::none());
        };

        let resolution = market.resolution.borrow();

        // market was dissolved
        if (resolution.outcome.is_none()) {
            return (true, option::none());
        };


        if (resolution.outcome.borrow().resolution_timestamp + market.challenge_duration_sec <= timestamp::now_seconds() &&
            resolution.challenged_by.is_none()) {
            // Normal resolution and challenge period ended
            (true, option::some(resolution.outcome.borrow().outcome))
        } else if (resolution.challenged_outcome.is_some()) {
            // Challenged outcome is set and market is thus finalized
            (true, option::some(resolution.challenged_outcome.borrow().outcome))
        } else {
            // market was resolved, but challenge period not yet over
            (false, option::none())
        }
    }

    /// If the market was finalized and the final fee has not yet been collected, the final fee is withdrawn.
    /// The amount of the fees depends on the payout amount for the finalized market state.
    fun collect_market_finalized_fees(market_address: address, market: &mut Market) {
        if (market.is_final_fee_collected) {
            return;
        };
        let (is_final, result) = is_finalized_with_result_impl(market);

        if (!is_final) {
            return;
        };

        let vault_balance = primary_fungible_store::balance(market_address, market.vault_type);
        // Get the total value of all available LP tokens without taking into account LPS tokens,
        // since they are no IOUs for the LP and LPs don't get any tokens back for returning them.
        let (lp_token, _) = cpmm::lp_tokens(market.pool);
        let lp_supply = (*fungible_asset::supply(lp_token).borrow() as u64);
        let total_lp_value = cpmm::lp_value(market.pool, lp_supply, result);
        let remaining_shares_value = vault_balance - total_lp_value;

        // Calculate fee
        let (market_fee, creator_fee, lp_fee) = calculate_fee(
            market.sell_market_fee_numerator,
            market.sell_creator_fee_numerator,
            market.sell_lp_fee_numerator,
            remaining_shares_value
        );

        // Transfer all fees to their corresponding stores
        let vault = primary_fungible_store::primary_store(market_address, market.vault_type);
        dispatchable_fungible_asset::transfer(market_signer(market), vault, market.market_fee_store, market_fee);
        dispatchable_fungible_asset::transfer(market_signer(market), vault, market.creator_fee_store, creator_fee);
        dispatchable_fungible_asset::transfer(market_signer(market), vault, market.lp_fee_store, lp_fee);

        // Update the final collected flag to prevent redundant fee collection
        market.is_final_fee_collected = true;

        // Update the lp fee accumulator so that the collected fees are paid out on LP withdrawal
        let total_lp_liq = market.total_lp_liq;
        aggregator_v2::add(&mut market.acc_fee_per_liquidity, math64::mul_div(lp_fee, constants::price_scaling_factor(), total_lp_liq));
    }

    /// Calculate the market, creator, and lp fee for the provided amount
    inline fun calculate_fee(
        market_fee_numerator: u64,
        creator_fee_numerator: u64,
        lp_fee_numerator: u64,
        amount: u64
    ): (u64, u64, u64) {
        let market_fee = math64::mul_div(amount, market_fee_numerator, FEE_DENOMINATOR);
        let creator_fee = math64::mul_div(amount, creator_fee_numerator, FEE_DENOMINATOR);
        let lp_fee = math64::mul_div(amount, lp_fee_numerator, FEE_DENOMINATOR);
        (market_fee, creator_fee, lp_fee)
    }


    /// Extract all fees from the given asset. The fees are deposited into their corresponding stores and the asset
    /// with all fees deduced is returned together with the amount of the deduced market-, creator- and lp-fees.
    /// Since buy and sell orders can have different fee structures, we need to differentiate between the two.
    inline fun extract_fee(withdraw_from: FungibleAsset, market: &mut Market, is_buy: bool): (FungibleAsset, u64, u64, u64) {
        let market_fee_numerator = if (is_buy) market.buy_market_fee_numerator else market.sell_market_fee_numerator;
        let creator_fee_numerator = if (is_buy) market.buy_creator_fee_numerator else market.sell_creator_fee_numerator;
        let lp_fee_numerator = if (is_buy) market.buy_lp_fee_numerator else market.sell_lp_fee_numerator;

        let amount = fungible_asset::amount(&withdraw_from);
        let (market_fee, creator_fee, lp_fee) = calculate_fee(
            market_fee_numerator,
            creator_fee_numerator,
            lp_fee_numerator,
            amount
        );

        fungible_asset::deposit(market.market_fee_store, fungible_asset::extract(&mut withdraw_from, market_fee));
        fungible_asset::deposit(market.creator_fee_store, fungible_asset::extract(&mut withdraw_from, creator_fee));
        fungible_asset::deposit(market.lp_fee_store, fungible_asset::extract(&mut withdraw_from, lp_fee));

        // Update the accumulator for the LP fees to provide accurate lp fee payouts depending on the trading
        // volume after they provided liquidity
        let total_lp_liq = market.total_lp_liq;
        if (total_lp_liq != 0) {
            aggregator_v2::add(
                &mut market.acc_fee_per_liquidity,
                math64::mul_div(lp_fee, constants::price_scaling_factor(), total_lp_liq)
            );
        };

        (withdraw_from, market_fee, creator_fee, lp_fee)
    }

    /// Calculate how many tokens the LP gets from the LP fee vault, proportional to its stake and time
    /// providing the liquidity.
    fun fractional_lp_fee_payout(
        market: &mut Market,
        user: address,
        amount: u64,
        acc_fee_per_liquidity: u64,
        is_synthetic: bool,
    ): (u64, u64) {
        let lp_buyin = market.lp_buyin.borrow_mut(user);
        let (lp_token, lps_token) = cpmm::lp_tokens(market.pool);
        let user_lp_balance = primary_fungible_store::balance(user, lp_token);
        let user_lps_balance = primary_fungible_store::balance(user, lps_token);
        let total_amount = if (is_synthetic) lp_buyin.total_undercollaterized else lp_buyin.total_fully_collaterized;
        let fraction_denominator = if (is_synthetic) user_lps_balance else user_lp_balance;
        let payout_fraction = math64::mul_div(total_amount, amount, fraction_denominator);
        let payout = math64::mul_div(
            acc_fee_per_liquidity - lp_buyin.fee_per_liquidity,
            payout_fraction,
            constants::price_scaling_factor()
        );
        (payout, payout_fraction)
    }


    inline fun market_signer(market: &Market): &signer {
        &object::generate_signer_for_extending(&market.extend_ref)
    }

    /// Returns the prices for yes and no tokens, in that order.
    fun prices_impl(market: &Market): (u64, u64) {
        let (is_final, result) = is_finalized_with_result_impl(market);
        let token_prices = simple_map::new_from(
            vector[market.yes_token, market.no_token],
            vector[0, 0]
        );

        if (is_final && result.is_some()) {
            // If the market's resolution is final, the resolved case is always worth 1 full unit
            let result = *result.borrow();
            token_prices.upsert(result, math64::pow(10, (fungible_asset::decimals(result) as u64)));
        } else if (is_final && result.is_none()) {
            // Market was dissolved; we need to manually calculate the price by using the token balance of the cpmm
            // at time of resolution because if user sell their tokens after the market was dissolved, the cpmm balance
            // changes (and thus the price as well).
            let resolution = market.resolution.borrow();
            let (yes_price, no_price) = cpmm::calc_token_price(resolution.cpmm_yes, resolution.cpmm_no);
            token_prices.upsert(market.yes_token, yes_price);
            token_prices.upsert(market.no_token, no_price);
        } else {
            // Market is still running, so we use the token prices from the cpmm
            let res = cpmm::token_price(market.pool);
            token_prices.keys().for_each(|key| {token_prices.upsert(key, *res.borrow(&key));});
        };
        (*token_prices.borrow(&market.yes_token), *token_prices.borrow(&market.no_token))
    }

    #[test_only]
    public fun metadata_address(asset_symbol: vector<u8>): address acquires MarketGlobalState {
        let global_state = borrow_global<MarketGlobalState>(@panana);
        object::create_object_address(&address_from_extend_ref(&global_state.extend_ref), asset_symbol)
    }

    #[test_only]
    public fun metadata(asset_symbol: vector<u8>): Object<Metadata> acquires MarketGlobalState {
        object::address_to_object(metadata_address(asset_symbol))
    }

    #[test_only]
    public fun fees(market_obj: Object<Market>): (u64, u64, u64) acquires Market {
        let market = borrow_global<Market>(object::object_address(&market_obj));
        (fungible_asset::balance(market.market_fee_store), fungible_asset::balance(
            market.creator_fee_store
        ), fungible_asset::balance(market.lp_fee_store))
    }

    #[test_only]
    public fun get_lp_tokens(market_obj: Object<Market>): (Object<Metadata>, Object<Metadata>) acquires Market {
        let market = borrow_global<Market>(object::object_address(&market_obj));
        cpmm::lp_tokens(market.pool)
    }

    #[test_only]
    public fun init_test(aptos_framework: &signer, account: &signer) {
        init_module(account);
        timestamp::set_time_has_started_for_testing(aptos_framework);
        cpmm::init_test(account);
        config::init_test(account);
    }
}