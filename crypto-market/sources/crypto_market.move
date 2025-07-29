module panana::crypto_market {
    use std::bcs::to_bytes;
    use std::signer;
    use std::timestamp;
    use std::object;
    use std::option;
    use std::option::Option;
    use std::signer::address_of;
    use std::vector;
    use aptos_std::math64;
    use aptos_std::ordered_map;
    use aptos_std::pool_u64_unbound;
    use aptos_std::pool_u64_unbound::Pool;
    use aptos_std::smart_vector;
    use aptos_framework::event;
    use aptos_framework::fungible_asset;
    use aptos_framework::fungible_asset::{Metadata, FungibleAsset};
    use aptos_framework::object::{Object, object_address, ExtendRef, generate_signer_for_extending,
        create_named_object, generate_signer, object_from_constructor_ref, address_to_object,
        address_from_extend_ref, generate_extend_ref
    };
    use aptos_framework::primary_fungible_store;
    use pyth::price_info;
    use pyth::price_feed;
    use pyth::i64;
    use pyth::price;
    use pyth::price_identifier;
    use panana::vaa_parser;

    // Error when the user is not authorized to perform an action
    const E_UNAUTHORIZED: u64 = 1;
    // Error when we try to get a market that doesn't exist
    const E_MARKET_DOES_NOT_EXIST: u64 = 2;
    // Error if the placed bet is lower than the minimum requried amount
    const E_BET_TOO_LOW: u64 = 3;
    // Rewards cannot be claimed if there are no rewards for a user on a market
    const E_NO_REWARDS: u64 = 4;
    // If the VAA's price id does not match the market's price id
    const E_INVALID_PRICE_ID: u64 = 5;
    // If the VAA's timestamp does not match the market's timestamp
    const E_INVALID_TIMESTAMP: u64 = 6;
    // Error if the vaas could be parsed, but the price for a market couldn't be found
    const E_PRICE_NOT_FOUND: u64 = 7;
    // Interactions as user with a market are not possible if the crypto series is frozen
    const E_FROZEN: u64 = 8;
    // Duration of a crypto series must not be zero
    const E_DURATION_ZERO: u64 = 9;
    // Fee of a crypto series must be less than 100%
    const E_FEE_TOO_HIGH: u64 = 10;

    // Static fee donimator to allow fees in permille (percent with up to 2 decimals)
    const FEE_DENOMINATOR: u64 = 10_000;

    /// Emitted wheenver a new bet was palced
    #[event]
    struct PlaceBetEvent has drop, store {
        sender: address,
        market_series_obj: Object<CryptoMarketSeries>,
        fa_metadata: Object<Metadata>,
        bet_up: bool,
        value: u64,
        market_index: u64,
    }

    /// Emitted wheenver rewards are claimed from a user
    #[event]
    struct ClaimRewardsEvent has drop, store {
        sender: address,
        crypto_series_obj: Object<CryptoMarketSeries>,
        fa_metadata: Object<Metadata>,
        market_resolved_up: bool,
        market_index: u64,
        value: u64,
        emitted_timestamp_sec: u64,
    }

    /// A CryptoMarketSeries is a parent structure for all crypto markets and defined by its input token, the duration,
    /// and the asset the user can bet on (=pyth price id).
    struct CryptoMarketSeries has key {
        pyth_price_id: vector<u8>,
        extend_ref: object::ExtendRef,
        open_sec: u64,
        betting_token: Object<Metadata>,
        fee_numerator: u64,
        min_bet: u64,
        series_start_timestamp_sec: u64,
        is_frozen: bool,
    }

    /// Global state
    struct CryptoMarketGlobalState has key {
        extend_ref: ExtendRef,
    }

    /// Unclaimed markets represent all markets where a user still has stake in.
    struct UnclaimedMarkets has key {
        // Markets are removed from this map once they're claimed, so we don't expect the vector to grow too big.
        // We should switch this implementation from vector to Set once it's available.
        markets: ordered_map::OrderedMap<Object<CryptoMarketSeries>, smart_vector::SmartVector<u64>>,
    }

    /// A crypto market tracks all user shares and bets.
    struct CryptoMarket has key, store {
        // shares for all users who voted up
        up_pool: Pool,
        // shares for all user who voted down
        down_pool: Pool,
        // Extend ref for the market to manage the vault
        extend_ref: ExtendRef,
    }

    /// Initialize the module's global state
    fun init_module(account: &signer) {
        let constructor_ref = object::create_object(signer::address_of(account));
        let extend_ref = object::generate_extend_ref(&constructor_ref);

        move_to(account, CryptoMarketGlobalState {
            extend_ref,
        });
    }

    /// Create a crypto series object. A crypto series is defined by the token used for predicting, the pyth oracle used
    /// to resolve the market (=token to predict on), and the market duration.
    /// The resulting object is determinstically defined by all 3 parameters. This allows us to have different
    /// crypto markets for each token to predict on and predict with, as well as different market durations for all token
    /// combinations.
    public entry fun create_crypto_series(
        account: &signer,
        betting_token: Object<Metadata>,
        pyth_price_id: vector<u8>,
        open_duration_sec: u64,
        min_bet: u64,
        fee_numerator: u64,
        first_market_timestamp_sec: u64,
    ) acquires CryptoMarketGlobalState {
        assert!(min_bet > 0, E_BET_TOO_LOW);
        assert!(open_duration_sec > 0, E_DURATION_ZERO);
        assert!(fee_numerator < FEE_DENOMINATOR, E_FEE_TOO_HIGH);
        assert!(address_of(account) == @admin, E_UNAUTHORIZED);

        let object_seed = series_seed(betting_token, pyth_price_id, open_duration_sec);

        let global_state = borrow_global<CryptoMarketGlobalState>(@panana);
        let global_signer = generate_signer_for_extending(&global_state.extend_ref);

        let obj_constructor_ref = object::create_named_object(&global_signer, object_seed);
        let obj_signer = object::generate_signer(&obj_constructor_ref);
        let extend_ref = object::generate_extend_ref(&obj_constructor_ref);

        move_to(&obj_signer, CryptoMarketSeries {
            pyth_price_id,
            extend_ref,
            open_sec: open_duration_sec,
            betting_token,
            min_bet,
            fee_numerator,
            series_start_timestamp_sec: first_market_timestamp_sec,
            is_frozen: false,
        });
    }

    /// Update the provided crypto series
    public entry fun update_crypto_series(
        account: &signer,
        crypto_series_obj: Object<CryptoMarketSeries>,
        fee_numerator: Option<u64>,
        min_bet: Option<u64>
    ) acquires CryptoMarketSeries {
        min_bet.for_each_ref(|value| assert!(*value > 0, E_BET_TOO_LOW));
        fee_numerator.for_each_ref(|numerator| assert!(*numerator < FEE_DENOMINATOR, E_FEE_TOO_HIGH));
        assert!(signer::address_of(account) == @admin, E_UNAUTHORIZED);
        let crypto_series = borrow_global_mut<CryptoMarketSeries>(object::object_address(&crypto_series_obj));
        crypto_series.min_bet = *min_bet.borrow_with_default(&crypto_series.min_bet);
        crypto_series.fee_numerator = *fee_numerator.borrow_with_default(&crypto_series.fee_numerator);
    }

    /// Place bet places a new bet for the current market in the provided crypto market series.
    /// It automatically creates a new market if it's the first prediction on that market.
    public entry fun place_bet(
        account: &signer,
        crypto_series_obj: Object<CryptoMarketSeries>,
        fa_metadata: Object<Metadata>,
        bet_up: bool,
        value: u64
    ) acquires CryptoMarketSeries, UnclaimedMarkets, CryptoMarket {
        let crypto_series = borrow_global_mut<CryptoMarketSeries>(object::object_address(&crypto_series_obj));
        assert!(value >= crypto_series.min_bet, E_BET_TOO_LOW);
        assert!(!crypto_series.is_frozen, E_FROZEN);

        let current_timestamps_sec = timestamp::now_seconds();
        let market_index = calc_market_index(
            current_timestamps_sec,
            crypto_series.series_start_timestamp_sec,
            crypto_series.open_sec
        );

        let market_opt = market_obj_by_index(crypto_series_obj, market_index);
        // Create market if not exists
        if (market_opt.is_none()) {
            create_market_object(crypto_series);

            let series_vault_balance = primary_fungible_store::balance(object_address(&crypto_series_obj), crypto_series.betting_token);
            // Set default stake to incentivize users to participate
            if (series_vault_balance >= crypto_series.min_bet * 2) {
                let series_signer = object::generate_signer_for_extending(&crypto_series.extend_ref);
                let (initial_up, initial_down) = (fungible_asset::zero(crypto_series.betting_token), fungible_asset::zero(crypto_series.betting_token));

                fungible_asset::merge(&mut initial_up, primary_fungible_store::withdraw(&series_signer, crypto_series.betting_token, crypto_series.min_bet));
                fungible_asset::merge(&mut initial_down, primary_fungible_store::withdraw(&series_signer, crypto_series.betting_token, crypto_series.min_bet));
                let series_signer = generate_signer_for_extending(&crypto_series.extend_ref);
                place_bet_impl(&series_signer, crypto_series_obj,  crypto_series, true, initial_up);
                place_bet_impl(&series_signer, crypto_series_obj,  crypto_series, false, initial_down);
            };
        };

        // Place user prediction
        let bet_value = primary_fungible_store::withdraw(account, fa_metadata, value);
        place_bet_impl(account, crypto_series_obj, crypto_series, bet_up, bet_value);
        event::emit(PlaceBetEvent{
            sender: signer::address_of(account),
            market_series_obj: crypto_series_obj,
            fa_metadata,
            bet_up,
            value: value,
            market_index,
        });
    }

    /// Claim rewards for a specific market. The user needs to provide the pyth vaas, which are validated on-chain.
    /// If they are correct, the user is allowed to claim the rewards.
    public entry fun claim_rewards(
        account: &signer,
        crypto_series_obj: Object<CryptoMarketSeries>,
        market_index: u64,
        start_price_pyth_vaa: vector<u8>,
        end_price_pyth_vaa: vector<u8>,
    ) acquires UnclaimedMarkets, CryptoMarketSeries, CryptoMarket {
        let account_address = signer::address_of(account);
        let crypto_series = borrow_global<CryptoMarketSeries>(object_address(&crypto_series_obj));
        assert!(!crypto_series.is_frozen, E_FROZEN);
        assert!(can_claim_rewards(account_address, crypto_series_obj, crypto_series, market_index), E_NO_REWARDS);

        let (start_price, end_price) = get_and_validate_pyth_prices_for_market(crypto_series, market_index, start_price_pyth_vaa, end_price_pyth_vaa);
        claim_all_rewards(account, crypto_series_obj, crypto_series, market_index, market_resolved_up(start_price, end_price));
    }

    /// Fees accumulate in the crypto series vault. This function allows the withdrawal of the vault.
    /// Withdrawal is limited to the admin to prevent malicious use.
    public entry fun withdraw_series_vault(
        account: &signer,
        crypto_series_obj: Object<CryptoMarketSeries>,
        value: u64,
    ) acquires CryptoMarketSeries {
        assert!(signer::address_of(account) == @admin, E_UNAUTHORIZED);

        let crypto_series  = borrow_global_mut<CryptoMarketSeries>(object::object_address(&crypto_series_obj));
        let series_signer = object::generate_signer_for_extending(&crypto_series.extend_ref);
        primary_fungible_store::transfer(&series_signer, crypto_series.betting_token, @admin, value);
    }

    /// Freeze and unfreeze provided crypto series markets.
    public entry fun freeze_crypto_series(account: &signer, crypto_series_obj: Object<CryptoMarketSeries>, freeze: bool) acquires CryptoMarketSeries {
        assert!(signer::address_of(account) == @admin, E_UNAUTHORIZED);
        let crypto_series = borrow_global_mut<CryptoMarketSeries>(object_address(&crypto_series_obj));
        crypto_series.is_frozen = freeze;
    }

    /// Validate the pyth vaa prices from the provided vaas.
    /// Errors if the provided VAAs are invalid.
    fun get_and_validate_pyth_prices_for_market(
        crypto_series: &CryptoMarketSeries,
        market_index: u64,
        start_price_pyth_vaa: vector<u8>,
        end_price_pyth_vaa: vector<u8>,
    ): (u64, u64) {
        let (start_time, end_time) = start_and_end_timestamp_sec(
            market_index,
            crypto_series.series_start_timestamp_sec,
            crypto_series.open_sec
        );
        (
            parse_and_validate_pyth_vaa_price(start_price_pyth_vaa, crypto_series.pyth_price_id, start_time),
            parse_and_validate_pyth_vaa_price(end_price_pyth_vaa, crypto_series.pyth_price_id, end_time),
        )
    }

    /// Calculate the start and end timestamp for the provided market index
    inline fun start_and_end_timestamp_sec(market_index: u64, first_timestamp_sec: u64, open_sec: u64): (u64, u64) {
        (
            first_timestamp_sec + market_index * open_sec,
            first_timestamp_sec + (market_index + 1) * open_sec
        )
    }


    /// Create a new market object as a child of the provided crypto market series.
    fun create_market_object(crypto_series: &CryptoMarketSeries): Object<CryptoMarket> {
        let series_signer = object::generate_signer_for_extending(&crypto_series.extend_ref);

        let market_index = calc_market_index(timestamp::now_seconds(), crypto_series.series_start_timestamp_sec, crypto_series.open_sec);
        let market_constructor_ref = create_named_object(&series_signer, to_bytes(&market_index));
        let market_signer = generate_signer(&market_constructor_ref);
        let extend_ref = generate_extend_ref(&market_constructor_ref);

        let market = CryptoMarket {
            up_pool: pool_u64_unbound::new(),
            down_pool: pool_u64_unbound::new(),
            extend_ref,
        };

        move_to(&market_signer, market);
        object_from_constructor_ref<CryptoMarket>(&market_constructor_ref)
    }

    /// Place a new bet and add it to the user's unclaimed bets
    fun place_bet_impl(
        account: &signer,
        crypto_series_obj: Object<CryptoMarketSeries>,
        crypto_series: &CryptoMarketSeries,
        bet_up: bool,
        tokens: FungibleAsset,
    ) acquires UnclaimedMarkets, CryptoMarket {
        let current_timestamp = timestamp::now_seconds();
        let market_index = calc_market_index(current_timestamp, crypto_series.series_start_timestamp_sec, crypto_series.open_sec);

        let market_ref = market_ref(crypto_series_obj, market_index);

        let token_value = fungible_asset::amount(&tokens);
        let fee = math64::mul_div(token_value,  crypto_series.fee_numerator, FEE_DENOMINATOR);
        let fee_tokens = fungible_asset::extract(&mut tokens, fee);
        let token_value_without_fee = fungible_asset::amount(&tokens);

        primary_fungible_store::deposit(object_address(market_obj_by_index(crypto_series_obj, market_index).borrow()), tokens);
        primary_fungible_store::deposit(object_address(&crypto_series_obj), fee_tokens);

        let pool = if (bet_up) &mut market_ref.up_pool else &mut market_ref.down_pool;
        pool.buy_in(signer::address_of(account), token_value_without_fee);

        let account_address = signer::address_of(account);
        if (!exists<UnclaimedMarkets>(account_address)) {
            move_to(account, UnclaimedMarkets {
                markets: ordered_map::new(),
            });
        };
        let unclaimed_markets_ref = borrow_global_mut<UnclaimedMarkets>(account_address);

        if (!unclaimed_markets_ref.markets.contains(&crypto_series_obj)) {
            unclaimed_markets_ref.markets.add(crypto_series_obj, smart_vector::new());
        };

        let unclaimed_markets_in_config = unclaimed_markets_ref.markets.borrow_mut(&crypto_series_obj);
        if (!unclaimed_markets_in_config.contains(&market_index)) {
            unclaimed_markets_in_config.push_back(market_index);
        }
    }

    /// Helper to determine if the market resolved up.
    inline fun market_resolved_up(start_price: u64, end_price: u64): bool {
        end_price > start_price
    }

    /// Get the reward proportional to the user's input from the pool.
    fun redeem_reward_from_pool(
        market_ref: &mut CryptoMarket,
        market_signer: &signer,
        fa_metadata: Object<Metadata>,
        shareholder: address,
        market_resolved_up: bool
    ): FungibleAsset {
        let total_pool_coins = market_ref.up_pool.total_coins() + market_ref.down_pool.total_coins();

        let new_up_pool_coins = if(market_resolved_up) total_pool_coins else 0;
        let new_down_pool_coins = total_pool_coins - new_up_pool_coins;

        market_ref.up_pool.update_total_coins(new_up_pool_coins);
        market_ref.down_pool.update_total_coins(new_down_pool_coins);

        let reward_tokens = fungible_asset::zero(fa_metadata);
        if (market_resolved_up && market_ref.up_pool.contains(shareholder)) {
            let up_shares = market_ref.up_pool.shares(shareholder);
            let redeemed_up_coins = market_ref.up_pool.redeem_shares(shareholder, up_shares);

            fungible_asset::merge(&mut reward_tokens, primary_fungible_store::withdraw(market_signer, fa_metadata, redeemed_up_coins));
        };
        if (!market_resolved_up && market_ref.down_pool.contains(shareholder)) {
            let down_shares = market_ref.down_pool.shares(shareholder);
            let redeemed_down_coins = market_ref.down_pool.redeem_shares(shareholder, down_shares);
            fungible_asset::merge(&mut reward_tokens, dispatchable_fungible_asset::withdraw(market_signer, fa_metadata, redeemed_down_coins));
        };
        reward_tokens
    }

    /// Returns true if the user has pending rewards for the provided market.
    fun can_claim_rewards(account_address: address, crypto_series_obj: Object<CryptoMarketSeries>, crypto_series: &CryptoMarketSeries, market_index: u64): bool acquires UnclaimedMarkets {
        if (!exists<UnclaimedMarkets>(account_address)) {
            return false;
        };
        let unclaimed_markets = borrow_global_mut<UnclaimedMarkets>(account_address);
        if (!unclaimed_markets.markets.contains(&crypto_series_obj)) {
            return false
        };
        let unclaimed_markets_in_config = unclaimed_markets.markets.borrow(&crypto_series_obj);

        let current_market_idx = calc_market_index(timestamp::now_seconds(), crypto_series.series_start_timestamp_sec, crypto_series.open_sec);
        let is_market_closed = current_market_idx >= 2 && market_index <= current_market_idx - 2;
        unclaimed_markets_in_config.contains(&market_index) && is_market_closed
    }

    /// Collect all rewards for the user, as well as for our crypto series default stake
    fun claim_all_rewards(
        account: &signer,
        crypto_series_obj: Object<CryptoMarketSeries>,
        crypto_series: &CryptoMarketSeries,
        market_index: u64,
        market_resolved_up: bool,
    ) acquires UnclaimedMarkets, CryptoMarket {
        // claim user rewards
        let user_coin_reward = claim_rewards_impl(signer::address_of(account), crypto_series_obj, crypto_series, market_index, market_resolved_up);
        let user_coin_reward_value = fungible_asset::amount(&user_coin_reward);

        fungible_asset::deposit(primary_fungible_store::primary_store(signer::address_of(account), crypto_series.betting_token), user_coin_reward);

        // Automatically claim rewards of market
        let market_series_address = object::object_address(&crypto_series_obj);
        if (can_claim_rewards(market_series_address, crypto_series_obj, crypto_series, market_index)) {
            let amm_coin_reward = claim_rewards_impl(market_series_address, crypto_series_obj, crypto_series, market_index, market_resolved_up);
            primary_fungible_store::deposit(object_address(&crypto_series_obj), amm_coin_reward);
        };

        event::emit(ClaimRewardsEvent{
            sender: signer::address_of(account),
            crypto_series_obj,
            fa_metadata: crypto_series.betting_token,
            market_resolved_up,
            value: user_coin_reward_value,
            market_index,
            emitted_timestamp_sec: timestamp::now_seconds(),
        });
    }

    /// Claim rewards for the provided account and market
    fun claim_rewards_impl(
        account_address: address,
        crypto_series_obj: Object<CryptoMarketSeries>,
        crypto_series: &CryptoMarketSeries,
        market_index: u64,
        market_resolved_up: bool,
    ): FungibleAsset acquires UnclaimedMarkets, CryptoMarket {

        let market_obj = market_obj_by_index(crypto_series_obj, market_index);
        assert!(market_obj.is_some(), E_MARKET_DOES_NOT_EXIST);
        let market_ref = borrow_global_mut<CryptoMarket>(object_address(market_obj.borrow()));
        let market_signer = generate_signer_for_extending(&market_ref.extend_ref);

        let unclaimed_markets = borrow_global_mut<UnclaimedMarkets>(account_address);
        let unclaimed_markets_for_series = unclaimed_markets.markets.borrow_mut(&crypto_series_obj);
        let (found, unclaiemd_market_index) = unclaimed_markets_for_series.index_of(&market_index);
        if (!found) return fungible_asset::zero(crypto_series.betting_token);
        unclaimed_markets_for_series.remove(unclaiemd_market_index);

        let total_pool_coins = market_ref.up_pool.total_coins() + market_ref.down_pool.total_coins();

        let new_up_pool_coins = if(market_resolved_up) total_pool_coins else 0;
        let new_down_pool_coins = total_pool_coins - new_up_pool_coins;

        market_ref.up_pool.update_total_coins(new_up_pool_coins);
        market_ref.down_pool.update_total_coins(new_down_pool_coins);

        let reward_coins = fungible_asset::zero(crypto_series.betting_token);
        if (market_resolved_up && market_ref.up_pool.contains(account_address)) {
            let up_shares = market_ref.up_pool.shares(account_address);
            let redeemed_up_coins = market_ref.up_pool.redeem_shares(account_address, up_shares);

            fungible_asset::merge(&mut reward_coins, primary_fungible_store::withdraw(&market_signer, crypto_series.betting_token, redeemed_up_coins));
        };
        if (!market_resolved_up && market_ref.down_pool.contains(account_address)) {
            let down_shares = market_ref.down_pool.shares(account_address);
            let redeemed_down_coins = market_ref.down_pool.redeem_shares(account_address, down_shares);
            fungible_asset::merge(&mut reward_coins, dispatchable_fungible_asset::withdraw(&market_signer, crypto_series.betting_token, redeemed_down_coins));
        };
        reward_coins
    }

    /// Get a reference to the market at the provided index. Errors if the market does not exist.
    inline fun market_ref(market_series_obj: Object<CryptoMarketSeries>, market_index: u64): &mut CryptoMarket {
        let market_obj = market_obj_by_index(market_series_obj, market_index);
        assert!(market_obj.is_some(), E_MARKET_DOES_NOT_EXIST);
        borrow_global_mut<CryptoMarket>(object_address(market_obj.borrow()))
    }

    /// Parse the provided pyth vaa to get the price at a certain time.
    /// This function errors if the provided vaa could not be parsed or dopes not match the
    /// provided timestamp
    #[view]
    public fun parse_and_validate_pyth_vaa_price(pyth_vaa: vector<u8>, price_id: vector<u8>, timestamp: u64): u64 {
        let price_infos = vaa_parser::parse_and_verify_accumulator_message(pyth_vaa);
        let (found, index) = price_infos.find(|v| {
            let price_feed = price_info::get_price_feed(v);
            let price_identifier = price_identifier::get_bytes(price_feed::get_price_identifier(price_feed));
            let price_timestamp = price::get_timestamp(&price_feed::get_price(price_feed));
            assert!(price_identifier == price_id, E_INVALID_PRICE_ID);
            assert!(timestamp == price_timestamp, E_INVALID_TIMESTAMP);
            price_identifier == price_id && timestamp == price_timestamp
        });
        assert!(found, E_PRICE_NOT_FOUND);
        let price_info = price_infos.borrow(index);
        let price = i64::get_magnitude_if_positive(&price::get_price(&price_feed::get_price(price_info::get_price_feed(price_info))));
        price
    }

    /// Get the deterministic address of the crypto series for the provided parameters.
    #[view]
    public fun crypto_series(
        betting_token: Object<Metadata>,
        pyth_price_id: vector<u8>,
        market_duration: u64,
    ): Option<Object<CryptoMarketSeries>> acquires CryptoMarketGlobalState {
        let global_state = borrow_global<CryptoMarketGlobalState>(@panana);
        let series_address = object::create_object_address(&address_from_extend_ref(&global_state.extend_ref), series_seed(betting_token, pyth_price_id, market_duration));
        return if (!exists<CryptoMarketSeries>(series_address)) {
            option::none()
        } else {
            option::some(address_to_object<CryptoMarketSeries>(series_address))
        }
    }

    /// This function returns a vector of unclaimed markets for the provided account and crypto series.
    #[view]
    public fun unclaimed_markets(
        account_address: address,
        market_series_obj: Object<CryptoMarketSeries>,
    ): vector<u64> acquires UnclaimedMarkets {
        if (!exists<UnclaimedMarkets>(account_address)) {
            return vector::empty()
        };
        let unclaimed_markets = borrow_global<UnclaimedMarkets>(account_address);
        let unclaimed_markets_in_config = unclaimed_markets.markets.borrow(&market_series_obj);
        unclaimed_markets_in_config.to_vector()
    }

    /// Compute the seed for the provided parameters to create a deterministic address.
    inline fun series_seed(
        betting_token: Object<Metadata>,
        pyth_price_id: vector<u8>,
        market_duration: u64,
    ): vector<u8> {
        let object_seed = to_bytes(&object_address(&betting_token));
        object_seed.append(pyth_price_id);
        object_seed.append(to_bytes(&market_duration));
        object_seed
    }


    /// Calculate the market index for the provided parameters.
    inline fun calc_market_index(timestamp_sec: u64, first_market_timestamp_sec: u64, open_duration_sec: u64): u64 {
        (timestamp_sec - first_market_timestamp_sec) / open_duration_sec
    }

    /// Get the stake for a specific shareholder in the given amrket.
    #[view]
    public fun stake_by_address(
        market_series_obj: Object<CryptoMarketSeries>,
        market_index: u64,
        shareholder: address,
    ): (u64, u64) acquires  CryptoMarket {
        let market = market_ref(market_series_obj, market_index);
        (
            market.up_pool.shares_to_amount(market.up_pool.shares(shareholder)),
            market.down_pool.shares_to_amount(market.down_pool.shares(shareholder)),
        )
    }

    /// Get the market object for the provided index. If no market was created for the provided index, empty is returned.
    #[view]
    public fun market_obj_by_index(market_series_obj: Object<CryptoMarketSeries>, market_index: u64): Option<Object<CryptoMarket>> {
        let market_address = object::create_object_address(&object_address(&market_series_obj), to_bytes(&market_index));
        if (exists<CryptoMarket>(market_address)) {
            option::some(address_to_object<CryptoMarket>(market_address))
        } else {
            option::none()
        }
    }

    #[view]
    public fun shareholder_count(market_obj: Object<CryptoMarket>): (u64, u64) acquires CryptoMarket {
        let market_ref = borrow_global<CryptoMarket>(object_address(&market_obj));
        return (
            market_ref.up_pool.shareholders_count(),
            market_ref.down_pool.shareholders_count(),
        )
    }

    // returns up_bets, down_bets, up_bets_sum, down_bets_sum, series_vault, market_vault
    #[test_only]
    public fun bets_data(market_series_obj: Object<CryptoMarketSeries>, market_index: u64): (u64, u64, u64, u64, u64, u64) acquires CryptoMarket, CryptoMarketSeries {
        let market_series = borrow_global<CryptoMarketSeries>(object_address(&market_series_obj));
        let market_obj = market_obj_by_index(market_series_obj, market_index);
        let market_ref = market_ref(market_series_obj, market_index);
        (
            market_ref.up_pool.shareholders_count(),
            market_ref.down_pool.shareholders_count(),
            market_ref.up_pool.total_coins(),
            market_ref.down_pool.total_coins(),
            primary_fungible_store::balance(object_address(&market_series_obj), market_series.betting_token),
            primary_fungible_store::balance(object_address(market_obj.borrow()), market_series.betting_token),
        )
    }

    // Need custom claim rewards test function because we don't have vaas to properly test it with the real function
    #[test_only]
    public fun claim_rewards_test(
        account: &signer,
        crypto_series_obj: Object<CryptoMarketSeries>,
        market_index: u64,
        start_price: u64,
        end_price: u64,
    ) acquires UnclaimedMarkets, CryptoMarketSeries, CryptoMarket {
        let account_address = signer::address_of(account);
        let crypto_series = borrow_global<CryptoMarketSeries>(object_address(&crypto_series_obj));
        assert!(can_claim_rewards(account_address, crypto_series_obj, crypto_series, market_index), E_NO_REWARDS);

        let market_resolved_up = market_resolved_up(start_price, end_price);
        claim_all_rewards(account, crypto_series_obj, crypto_series, market_index, market_resolved_up);
    }


    #[test_only]
    public fun init(account: &signer) {
        init_module(account);
    }
}
