module panana::cpmm {
    use std::option::Option;
    use std::signer;
    use aptos_std::math128;
    use aptos_std::math64;
    use aptos_std::simple_map;
    use aptos_std::simple_map::SimpleMap;
    use aptos_framework::event;
    use aptos_framework::fungible_asset;
    use aptos_framework::fungible_asset::{FungibleStore, Metadata, FungibleAsset, BurnRef, MintRef,
        metadata_from_asset, store_metadata
    };
    use aptos_framework::object::{
        generate_extend_ref,
        generate_signer_for_extending,
        object_address,
        ExtendRef,
        Object,
        address_to_object,
        create_object,
        create_object_address,
    };
    use aptos_framework::primary_fungible_store;
    use panana::constants::price_scaling_factor;
    use panana::resource_utils;
    use panana::cpmm_utils;


    /// Only the market is allowed to access the cpmm
    friend panana::market;
    #[test_only]
    friend panana::cpmm_test;

    /// Asset metadata must be properly paired.
    const E_INVALID_ASSETS: u64 = 1;
    /// Supplied token amount must match expectations
    const E_AMOUNT_MISMATCH: u64 = 2;
    /// The provided liquidity must exceed minimum threshold
    const E_INSUFFICIENT_INITIAL_LIQ: u64 = 3;
    /// A pool for the provided asset pair already exists
    const E_POOL_EXISTS: u64 = 4;
    /// No pool for the given asset pair
    const E_POOL_NOT_FOUND: u64 = 5;
    /// The provided LP token does not belong to this pool
    const E_INVALID_LP_TOKEN: u64 = 6;
    /// The swap operation produced a zero output, which is invalid
    const E_SWAP_ZERO_OUTPUT: u64 = 7;
    /// If actual output < min slippage
    const E_SLIPPAGE_EXCEEDED: u64 = 8;

    /// Emitted whenever a new pool was created
    #[event]
    enum PoolCreatedEvent has drop, store {
        V1 {
            pool: Object<LiquidityPool>,
            token_a: Object<Metadata>,
            token_b: Object<Metadata>,
            token_lp: Object<Metadata>,
            token_lps: Object<Metadata>,
            initial_a: u64,
            initial_b: u64,
            lp_out: u64,
            is_synthetic: bool,
        }
    }

    /// Emitted whenever liquidity was added to a pool
    #[event]
    enum LiquidityAddedEvent has drop, store {
        V1 {
            pool: Object<LiquidityPool>,
            token_a: Object<Metadata>,
            token_b: Object<Metadata>,
            token_lp: Object<Metadata>,
            token_lps: Object<Metadata>,
            lp_out: u64,
            in_a: u64,
            in_b: u64,
            is_synthetic: bool,
        }
    }

    /// Emitted whenever liquidity was removed from a pool
    #[event]
    enum LiquidityRemovedEvent has drop, store {
        V1 {
            pool: Object<LiquidityPool>,
            token_a: Object<Metadata>,
            token_b: Object<Metadata>,
            token_lp: Object<Metadata>,
            token_lps: Object<Metadata>,
            burned_lp: u64,
            out_a: u64,
            out_b: u64,
            is_synthetic: bool,
        }
    }

    /// Emitted whenever a swap was performed
    #[event]
    enum SwapEvent has drop, store {
        V1 {
            pool: Object<LiquidityPool>,
            token_in: Object<Metadata>,
            token_out: Object<Metadata>,
            input_amount: u64,
            output_amount: u64,
        }
    }


    /// Global state only holds an extend_ref needed for module-level objects.
    struct AMMGlobalState has key {
        extend_ref: ExtendRef,
    }

    /// A pool object for a given ordered asset pair.
    struct LiquidityPool has key, store {
        token_a_metadata: Object<Metadata>,
        token_b_metadata: Object<Metadata>,
        token_a_vault: Object<FungibleStore>,
        token_b_vault: Object<FungibleStore>,
        lp_token: Object<Metadata>,
        lp_mint_ref: MintRef,
        lp_burn_ref: BurnRef,
        lps_token: Object<Metadata>,
        lps_mint_ref: MintRef,
        lps_burn_ref: BurnRef,
        extend_ref: ExtendRef,
    }

    /// Initialize module global state
    fun init_module(account: &signer) {
        let ctor = create_object(signer::address_of(account));
        let extend_ref = generate_extend_ref(&ctor);
        move_to(account, AMMGlobalState { extend_ref });
    }

    /// Creates a new pool named by the ordered asset pair identifier.
    /// Returns the LP token minted and the pool object handle.
    /// Liquidity pool can be undercollaterized, returning
    /// LPS (synthetic liquidity provider) tokens instead of LP tokens
    public(friend) fun create_liquidity_pool(
        token_a: FungibleAsset,
        token_b: FungibleAsset,
        lp_token_symbol: vector<u8>,
        lps_token_symbol: vector<u8>,
        is_synthetic: bool,
    ): (FungibleAsset, Object<LiquidityPool>) acquires AMMGlobalState {
        let (token_a, token_b) = cpmm_utils::order_tokens(token_a, token_b);

        // Validate metadata distinctness and equal amounts
        let meta_a = fungible_asset::metadata_from_asset(&token_a);
        let meta_b = fungible_asset::metadata_from_asset(&token_b);
        assert!(object_address(&meta_a) != object_address(&meta_b), E_INVALID_ASSETS);

        let amt = fungible_asset::amount(&token_a);
        assert!(amt == fungible_asset::amount(&token_b), E_AMOUNT_MISMATCH);
        assert!(amt > 100, E_INSUFFICIENT_INITIAL_LIQ);

        // Derive deterministic seed for named object
        let seed = cpmm_utils::ordered_asset_pair_identifier(meta_a, meta_b);

        // Create the pool object (non-deletable, deterministic address)
        let (pool_signer, pool_extend_ref, pool_address) = resource_utils::create_seed_object(&global_signer(), seed);

        // Create vaults under the pool object
        let token_a_store = primary_fungible_store::ensure_primary_store_exists(pool_address, meta_a);
        let token_b_store = primary_fungible_store::ensure_primary_store_exists(pool_address, meta_b);

        // Deposit initial liquidity
        fungible_asset::deposit(token_a_store, token_a);
        fungible_asset::deposit(token_b_store, token_b);

        // Initialize LP token under pool
        let (lp_mint, lp_burn, lp_token_obj) = resource_utils::create_token(&pool_extend_ref, lp_token_symbol);
        let (lps_mint, lps_burn, lps_token_obj) = resource_utils::create_token(&pool_extend_ref, lps_token_symbol);

        let mint_ref = if (is_synthetic) &lps_mint else &lp_mint;

        let payout = fungible_asset::mint(mint_ref, amt);

        // Publish the pool resource into the pool object
        let pool = LiquidityPool {
            token_a_metadata: meta_a,
            token_b_metadata: meta_b,
            token_a_vault: token_a_store,
            token_b_vault: token_b_store,
            lp_token: lp_token_obj,
            lp_mint_ref: lp_mint,
            lp_burn_ref: lp_burn,
            lps_token: lps_token_obj,
            lps_mint_ref: lps_mint,
            lps_burn_ref: lps_burn,
            extend_ref: pool_extend_ref,
        };
        move_to(&pool_signer, pool);

        let pool_obj = address_to_object<LiquidityPool>(pool_address);
        event::emit(
            PoolCreatedEvent::V1 { pool: pool_obj, initial_a: amt, initial_b: amt, lp_out: amt, token_a: meta_a, token_b: meta_b, token_lp: lp_token_obj, token_lps: lps_token_obj, is_synthetic }
        );

        (payout, pool_obj)
    }

    /// Adds liquidity to an existing pool object.
    /// The provided tokens are either added completely, or only a fraction to preserve the price ration.
    /// Leftover tokens are returned to the caller. The leftover can be 0 for both input tokens.
    /// Returns (LP minted, unused A, unused B).
    public(friend) fun add_liquidity(
        pool_obj: Object<LiquidityPool>,
        token_a_max: FungibleAsset,
        token_b_max: FungibleAsset,
        is_synthetic: bool,
    ): (FungibleAsset, FungibleAsset, FungibleAsset) acquires LiquidityPool {
        let (token_a_max, token_b_max) = cpmm_utils::order_tokens(token_a_max, token_b_max);

        let meta_a = fungible_asset::metadata_from_asset(&token_a_max);
        let meta_b = fungible_asset::metadata_from_asset(&token_b_max);

        let p = borrow_global<LiquidityPool>(object_address(&pool_obj));

        // Ensure correct token pairing
        assert!(object_address(&meta_a) == object_address(&p.token_a_metadata), E_INVALID_ASSETS);
        assert!(object_address(&meta_b) == object_address(&p.token_b_metadata), E_INVALID_ASSETS);

        let reserve_a = fungible_asset::balance(p.token_a_vault);
        let reserve_b = fungible_asset::balance(p.token_b_vault);
        let amt_a = fungible_asset::amount(&token_a_max);
        let amt_b = fungible_asset::amount(&token_b_max);
        let (use_a, use_b) = calculate_liquidity(reserve_a, reserve_b, amt_a, amt_b);

        let lp_supply = *fungible_asset::supply(p.lp_token).borrow();
        let lps_supply = *fungible_asset::supply(p.lps_token).borrow();
        let total_lp_supply = lp_supply + lps_supply;

        let lp_out_amount = (math128::min(
            math128::mul_div((use_a as u128), total_lp_supply, (reserve_a as u128)),
            math128::mul_div((use_b as u128), total_lp_supply, (reserve_b as u128))
        ) as u64);

        let a_input = fungible_asset::extract(&mut token_a_max, use_a);
        let b_input = fungible_asset::extract(&mut token_b_max, use_b);
        fungible_asset::deposit(p.token_a_vault, a_input);
        fungible_asset::deposit(p.token_b_vault, b_input);


        let mint_ref = if (is_synthetic) &p.lps_mint_ref else &p.lp_mint_ref;
        let lp_out = fungible_asset::mint(mint_ref, lp_out_amount);

        event::emit(
            LiquidityAddedEvent::V1 { pool: pool_obj, in_a: use_a, in_b: use_b, lp_out: lp_out_amount, token_a: meta_a, token_b: meta_b, token_lp: p.lp_token, token_lps: p.lps_token, is_synthetic }
        );

        (lp_out, token_a_max, token_b_max)
    }

    /// Burns LP tokens and withdraws proportional tokens from the pool's token pair.
    public(friend) fun remove_liquidity(
        pool: Object<LiquidityPool>,
        lp_tokens: FungibleAsset,
    ): (FungibleAsset, FungibleAsset) acquires LiquidityPool {
        let pool_addr = object_address(&pool);
        let p = borrow_global_mut<LiquidityPool>(pool_addr);
        let is_synthetic = metadata_from_asset(&lp_tokens) == p.lps_token;
        assert!(metadata_from_asset(&lp_tokens) == p.lp_token || is_synthetic, E_INVALID_LP_TOKEN);

        let amt_lp = fungible_asset::amount(&lp_tokens);

        let burn_ref = if (is_synthetic) &p.lps_burn_ref else &p.lp_burn_ref;
        fungible_asset::burn(burn_ref, lp_tokens);

        let reserve_a = fungible_asset::balance(p.token_a_vault);
        let reserve_b = fungible_asset::balance(p.token_b_vault);

        let (out_a, out_b) = simulate_sell_liquidity(reserve_a, reserve_b, amt_lp);

        let pool_signer = generate_signer_for_extending(&p.extend_ref);
        let w_a = fungible_asset::withdraw(&pool_signer, p.token_a_vault, out_a);
        let w_b = fungible_asset::withdraw(&pool_signer, p.token_b_vault, out_b);

        event::emit(
            LiquidityRemovedEvent::V1 { pool, burned_lp: amt_lp, out_a, out_b, token_a: p.token_a_metadata, token_b: p.token_b_metadata, token_lp: p.lp_token, token_lps: p.lps_token, is_synthetic }
        );
        (w_a, w_b)
    }

    /// Executes a swap on the pool: `token_in` -> opposite token.
    /// To prevent high slippage, the execution is aborted if the amount of output tokens
    /// is below the slippage_min parameter.
    public(friend) fun swap(
        pool: Object<LiquidityPool>,
        token_in: FungibleAsset,
        slippage_min: u64,
    ): FungibleAsset acquires LiquidityPool {
        let pool_addr = object_address(&pool);
        let p = borrow_global_mut<LiquidityPool>(pool_addr);
        let pool_signer = generate_signer_for_extending(&p.extend_ref);

        let amt_in = fungible_asset::amount(&token_in);
        // assert!(amt_in > 0, E_AMOUNT_MISMATCH);

        let is_a = fungible_asset::metadata_from_asset(&token_in) == fungible_asset::store_metadata(p.token_a_vault);
        let (in_vault, out_vault) = if (is_a) { (p.token_a_vault, p.token_b_vault) } else { (p.token_b_vault, p.token_a_vault) };

        let in_vault_balance = fungible_asset::balance(in_vault);
        let new_in_vault_balance = in_vault_balance + amt_in;
        let out_vault_balance = fungible_asset::balance(out_vault);
        let amt_out = math64::mul_div(out_vault_balance, amt_in, new_in_vault_balance);

        assert!(amt_out >= slippage_min, E_SLIPPAGE_EXCEEDED);

        fungible_asset::deposit(in_vault, token_in);

        let token_in_meta = fungible_asset::store_metadata(in_vault);
        let token_out_meta = fungible_asset::store_metadata(out_vault);
        event::emit(
            SwapEvent::V1 { pool, input_amount: amt_in, output_amount: amt_out, token_in: token_in_meta, token_out: token_out_meta }
        );

        fungible_asset::withdraw(&pool_signer, out_vault, amt_out)
    }

    /// Helper to compute the amount of liquidity required to preserve the pool ratio.
    /// tokens_a and tokens_b are the input token balances.
    /// max_a and max_b are the maximum amount of tokens to add to the pool
    /// Returns how many tokens of a and b need to be added to preserve the pool ratio.
    /// returned_a <= max_a and returned_b <= max_b
    fun calculate_liquidity(tokens_a: u64, tokens_b: u64, max_a: u64, max_b: u64): (u64, u64) {
        let is_a_lim = (max_a as u128) * (tokens_b as u128) <= (max_b as u128) * (tokens_a as u128);
        if (is_a_lim) {
            let b = math64::mul_div(max_a, tokens_b, tokens_a);
            (max_a, b)
        } else {
            let a = math64::mul_div(max_b, tokens_a, tokens_b);
            (a, max_b)
        }
    }

    /// Utility function to get the global signer
    inline fun global_signer(): signer acquires AMMGlobalState {
        let global_state = borrow_global<AMMGlobalState>(@panana);
        generate_signer_for_extending(&global_state.extend_ref)
    }

    #[view]
    public fun lp_tokens(pool_obj: Object<LiquidityPool>): (Object<Metadata>, Object<Metadata>) acquires LiquidityPool {
        let pool = borrow_global<LiquidityPool>(object_address(&pool_obj));
        (pool.lp_token, pool.lps_token)
    }

    /// Get the liquidity/invariant of the provided pool.
    #[view]
    public fun liquidity(
        pool_obj: Object<LiquidityPool>
    ): u64 acquires LiquidityPool {
        let pool = borrow_global<LiquidityPool>(object_address(&pool_obj));
        let available_tokens = available_tokens_impl(pool);
        // debug::print(&*available_tokens.borrow(&pool.token_a_metadata));
        liquidity_impl(*available_tokens.borrow(&pool.token_a_metadata), *available_tokens.borrow(&pool.token_b_metadata))
    }

    /// Calculate the liquidity, which is the same as calculating the geometric mean of both assets.
    inline fun liquidity_impl(a: u64, b: u64): u64 {
        (math128::sqrt((a as u128) * (b as u128)) as u64)
    }

    /// Get the price for both pool assets.
    #[view]
    public fun token_price(
        pool: Object<LiquidityPool>,
    ): simple_map::SimpleMap<Object<Metadata>, u64> acquires LiquidityPool {
        let p = borrow_global<LiquidityPool>(object_address(&pool));
        let a = fungible_asset::balance(p.token_a_vault);
        let b = fungible_asset::balance(p.token_b_vault);
        let (price_a, price_b) = calc_token_price(a, b);
        simple_map::new_from(
            vector[store_metadata(p.token_a_vault), store_metadata(p.token_b_vault)],
            vector[price_a, price_b]
        )
    }

    /// Calculate the token price
    #[view]
    public fun calc_token_price(
        a: u64,
        b: u64,
    ): (u64, u64) {
        let sum = a + b;
        (math64::mul_div(b, price_scaling_factor(), sum), math64::mul_div(a, price_scaling_factor(), sum))
    }

    /// Get the pool address for the provided token pair.
    #[view]
    public fun pool_address(
        token_a: Object<Metadata>,
        token_b: Object<Metadata>,
    ): address acquires AMMGlobalState {
        let id = cpmm_utils::ordered_asset_pair_identifier(token_a, token_b);
        create_object_address(&signer::address_of(&global_signer()), id)
    }

    /// Simulate the sell liquidity to determine how many tokens the user gets for withdrawing X amount of liquidity
    #[view]
    public fun simulate_sell_liquidity(reserve_a: u64, reserve_b: u64, amount: u64): (u64, u64) {
        let total_liq = liquidity_impl(reserve_a, reserve_b);

        let out_a = math64::mul_div(amount, reserve_a, total_liq);
        let out_b = math64::mul_div(amount, reserve_b, total_liq);

        (out_a, out_b)
    }

    /// The token price changes depending on the liquidity of the pool and the amount of tokens bought.
    /// This function calculates the average token price.
    /// Example: Buy 100 Tokens
    ///
    /// initial price per token: 0.5
    /// price per token after buying 100 tokens: 0.75
    /// avg. price per token: (0.5 + 0.75) / 2 = 0.625
    #[view]
    public fun avg_token_price(
        pool: Object<LiquidityPool>,
        token_in_amount: u64,
    ): (u64, u64) acquires LiquidityPool {
        let p = borrow_global<LiquidityPool>(object_address(&pool));
        let a = fungible_asset::balance(p.token_a_vault);
        let b = fungible_asset::balance(p.token_b_vault);
        let (cur_a, cur_b) = calc_token_price(a, b);
        let (n_a, n_b) = simulate_token_change(a, b, token_in_amount);
        let (aft_a, aft_b) = calc_token_price(n_a, n_b);
        ((cur_a + aft_a) / 2, (cur_b + aft_b) / 2)
    }

    /// Returns the amount of available tokens from the pool's asset pair.
    #[view]
    public fun available_tokens(
        pool: Object<LiquidityPool>,
    ): SimpleMap<Object<Metadata>, u64> acquires LiquidityPool {
        let liquidity_pool = borrow_global<LiquidityPool>(object_address(&pool));
        available_tokens_impl(liquidity_pool)
    }

    /// Helper to get the number of tokens within the liquidity pool.
    inline fun available_tokens_impl(liquidity_pool: &LiquidityPool): SimpleMap<Object<Metadata>, u64> {
        simple_map::new_from(
            vector[liquidity_pool.token_a_metadata, liquidity_pool.token_b_metadata],
            vector[fungible_asset::balance(liquidity_pool.token_a_vault), fungible_asset::balance(liquidity_pool.token_b_vault)],
        )
    }

    /// Simulate the token price change for adding X amount of tokens.
    /// This function can be used to determine how a buy order would affect the token price
    /// without executing it.
    #[view]
    public fun simulate_token_price_change(
        in_vault_balance: u64,
        out_vault_balance: u64,
        token_in_amount: u64,
    ): (u64, u64) {
        let (new_in_vault_balance, new_out_vault_balance) = simulate_token_change(
            in_vault_balance,
            out_vault_balance,
            token_in_amount
        );
        calc_token_price(new_in_vault_balance, new_out_vault_balance)
    }

    /// Get the lp value of lp_amount tokens.
    #[view]
    public fun lp_value(
        pool: Object<LiquidityPool>,
        lp_amount: u64,
        resolved_to: Option<Object<Metadata>>
    ): u64 acquires LiquidityPool {
        let liquidity_pool = borrow_global<LiquidityPool>(object_address(&pool));
        let available_tokens = available_tokens_impl(liquidity_pool);

        let a_shares = *available_tokens.borrow(&liquidity_pool.token_a_metadata);
        let b_shares = *available_tokens.borrow(&liquidity_pool.token_b_metadata);
        if (a_shares == 0 || b_shares == 0) return 0;

        let lowest_outcome_shares = if (resolved_to.is_some()) {
            if (*resolved_to.borrow() == liquidity_pool.token_a_metadata) b_shares else a_shares
        } else {
            math64::max(a_shares, b_shares)
        };
        math64::mul_div(liquidity_impl(a_shares, b_shares), lp_amount, lowest_outcome_shares)
    }

    /// Simulate the pool's token change for adding X tokens.
    /// This function can be used to determine how adding X tokens would affect the total number of tokens within the pool.
    #[view]
    public fun simulate_token_change(
        in_vault_balance: u64,
        out_vault_balance: u64,
        token_in_amount: u64,
    ): (u64, u64) {
        let new_in = in_vault_balance + token_in_amount;
        let out_tokens = math64::mul_div(out_vault_balance, token_in_amount, new_in);
        (new_in, out_vault_balance - out_tokens)
    }

    /// Initialize the CPMM moduel for tests.
    #[test_only]
    public fun init_test(account: &signer) {
        init_module(account);
    }

    /// Create a PoolCreatedEvent for tests.
    #[test_only]
    public fun create_pool_created_event(
        pool: Object<LiquidityPool>,
        token_a: Object<Metadata>,
        token_b: Object<Metadata>,
        token_lp: Object<Metadata>,
        token_lps: Object<Metadata>,
        initial_a: u64,
        initial_b: u64,
        lp_out: u64,
        is_synthetic: bool
    ): PoolCreatedEvent {
        let event = PoolCreatedEvent::V1 {
            pool, token_a, token_b, token_lp, token_lps, initial_a, initial_b, lp_out, is_synthetic
        };
        return event
    }

    /// Create a LiquidityAddedEvent for tests.
    #[test_only]
    public fun create_liquidity_added_event(
        pool: Object<LiquidityPool>,
        token_a: Object<Metadata>,
        token_b: Object<Metadata>,
        token_lp: Object<Metadata>,
        token_lps: Object<Metadata>,
        in_a: u64,
        in_b: u64,
        lp_out: u64,
        is_synthetic: bool
    ): LiquidityAddedEvent {
        let event = LiquidityAddedEvent::V1 {
            pool, token_a, token_b, token_lp, token_lps, in_a, in_b, lp_out, is_synthetic
        };
        return event
    }

    /// Create a LiquidityRemovedEvent for tests.
    #[view]
    #[test_only]
    public fun create_liquidity_removed_event(
        pool: Object<LiquidityPool>,
        token_a: Object<Metadata>,
        token_b: Object<Metadata>,
        token_lp: Object<Metadata>,
        token_lps: Object<Metadata>,
        out_a: u64,
        out_b: u64,
        burned_lp: u64,
        is_synthetic: bool
    ): LiquidityRemovedEvent {
        let event = LiquidityRemovedEvent::V1 {
            pool, token_a, token_b, token_lp, token_lps, out_a, out_b, burned_lp, is_synthetic
        };
        return event
    }

    /// Create a SwapEvent for tests.
    #[view]
    #[test_only]
    public fun create_swap_event(
        pool: Object<LiquidityPool>,
        token_in: Object<Metadata>,
        token_out: Object<Metadata>,
        input_amount: u64,
        output_amount: u64
    ): SwapEvent {
        let event = SwapEvent::V1 {
            pool, token_in, token_out, input_amount, output_amount
        };
        return event
    }
}
