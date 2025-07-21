module panana::market_test {
    #[test_only]
    use std::option;
    #[test_only]
    use std::signer;
    #[test_only]
    use std::string;
    #[test_only]
    use std::string::utf8;
    #[test_only]
    use aptos_std::math64;
    #[test_only]
    use aptos_framework::aptos_account;
    #[test_only]
    use aptos_framework::aptos_coin;
    #[test_only]
    use aptos_framework::aptos_coin::{AptosCoin, initialize_for_test};
    #[test_only]
    use aptos_framework::coin;
    #[test_only]
    use aptos_framework::fungible_asset;
    #[test_only]
    use aptos_framework::object;
    #[test_only]
    use aptos_framework::object::{object_address};
    #[test_only]
    use aptos_framework::primary_fungible_store;
    #[test_only]
    use aptos_framework::timestamp;
    #[test_only]
    use panana::config;
    #[test_only]
    use panana::constants;
    #[test_only]
    use panana::cpmm;
    #[test_only]
    use panana::market;
    #[test_only]
    use panana::market::{lp_fees, metadata};

    const ASSET_SYMBOL_YES: vector<u8> = b"YES-0x00";
    const ASSET_SYMBOL_NO: vector<u8> = b"NO-0x00";
    const OCTAS_PER_APT: u64 = 100_000_000;

    #[test(aptos_framework = @aptos_framework, panana = @panana, user1 = @user1, market_creator = @admin)]
    public fun test_buy_in_and_sell(aptos_framework: &signer, panana: &signer, user1: &signer, market_creator: &signer) {
        let (burn_ref, mint_ref) = initialize_for_test(aptos_framework);
        market::init_test(aptos_framework, panana);

        let aptos_coin_metadata = *coin::paired_metadata<AptosCoin>().borrow();

        market::create_market(
            market_creator,
            aptos_coin_metadata,
            string::utf8(b"Will Panana be big?"),
            string::utf8(b"Great question with an obvious answer"),
            string::utf8(b"Always resolves to yes"),
            vector[string::utf8(b"https://panana.com")],
            0,
            1000 * OCTAS_PER_APT,
            1000 * OCTAS_PER_APT,
            0,
            0,
            0,
            0,
            0,
            0,
            false,
            true
        );
        let market_obj = market::market_by_id(0);

        let user_tokens = coin::coin_to_fungible_asset(coin::mint(5 * OCTAS_PER_APT, &mint_ref));
        aptos_account::deposit_fungible_assets(signer::address_of(user1), user_tokens);
        coin::destroy_burn_cap(burn_ref);
        coin::destroy_mint_cap(mint_ref);

        market::buy_shares(user1, market_obj, true, 5 * OCTAS_PER_APT, 9_9751_2437); // 5 APT -> >=0.5 APT per Share -> ~10 shares

        let user_balance = primary_fungible_store::balance(signer::address_of(user1), market::metadata(ASSET_SYMBOL_YES));
        assert!(user_balance == 9_9751_2437, 0); // user has bought ~10 shares

        market::sell_shares(user1, market_obj, true, 9_9751_2437, 4_8511_2500);

        let user_aptos_balance = primary_fungible_store::balance(signer::address_of(user1), aptos_coin_metadata);
        assert!(user_aptos_balance == 5 * OCTAS_PER_APT - 1, 0);

        let (price_yes, price_no) = market::prices(market_obj);
        assert!(is_equal_or_off_by_one(price_yes, 5000_0000), 0);
        assert!(is_equal_or_off_by_one(price_no, 5000_0000), 0);
    }

    #[test(aptos_framework = @aptos_framework, panana = @panana, user1 = @user1, market_creator = @admin)]
    public fun test_buy_in_and_sell_token_six_decimals(aptos_framework: &signer, panana: &signer, user1: &signer, market_creator: &signer) {
        let (burn_ref, mint_ref) = initialize_for_test(aptos_framework);
        coin::destroy_burn_cap(burn_ref);
        coin::destroy_mint_cap(mint_ref);

        market::init_test(aptos_framework, panana);

        let constructor_ref = object::create_sticky_object(signer::address_of(panana));


        primary_fungible_store::create_primary_store_enabled_fungible_asset(
            &constructor_ref,
            option::none(),
            utf8(ASSET_SYMBOL_YES),
            utf8(ASSET_SYMBOL_YES),
            6,
            utf8(b"https://app.panana-predictions.xyz/profile_pic.jpg"),
            utf8(b"https://panana-predictions.xyz"),
        );

        let mint_ref = fungible_asset::generate_mint_ref(&constructor_ref);
        let coins = fungible_asset::mint(&mint_ref, 100_000_000);
        let coins_metadata = fungible_asset::metadata_from_asset(&coins);
        fungible_asset::deposit (primary_fungible_store::ensure_primary_store_exists(signer::address_of(user1), coins_metadata), coins);

        let creastor_coins = fungible_asset::mint(&mint_ref, 100_000_000);
        fungible_asset::deposit (primary_fungible_store::ensure_primary_store_exists(signer::address_of(market_creator), coins_metadata), creastor_coins);

        market::create_market(
            market_creator,
            coins_metadata,
            string::utf8(b"Will Panana be big?"),
            string::utf8(b"Great question with an obvious answer"),
            string::utf8(b"Always resolves to yes"),
            vector[string::utf8(b"https://panana.com")],
            0,
            100_000_000,
            100_000_000,
            100,
            200,
            300,
            400,
            500,
            600,
            false,
            false
        );
        let market_obj = market::market_by_id(0);

        market::buy_shares(user1, market_obj, true, 5_000_000, 0);

        let user_balance = primary_fungible_store::balance(signer::address_of(user1), market::metadata(ASSET_SYMBOL_YES));
        assert!(user_balance == 9_189_016, 0); // user has bought ~10 shares
        let (x, y, z) = market::fees(market_obj);
        assert!(x == 50_000);
        assert!(y == 100_000);
        assert!(z == 150_000);


        market::sell_shares(user1, market_obj, true, 9_189_016, 0);

        let user_aptos_balance = primary_fungible_store::balance(signer::address_of(user1), coins_metadata);
        assert!(user_aptos_balance == 98_995_002, 0);
        let (x, y, z) = market::fees(market_obj);
        assert!(x == 237_999);
        assert!(y == 334_999);
        assert!(z == 431_999);
        assert!(x + y + z + 98_995_002 == 100_000_000 - 1);

        // prices must always be 8 decimals
        let (price_yes, price_no) = market::prices(market_obj);
        assert!(is_equal_or_off_by_one(price_yes, 5000_0000), 0);
        assert!(is_equal_or_off_by_one(price_no, 5000_0000), 0);

        market::resolve_market(market_creator, market_obj, metadata(ASSET_SYMBOL_YES));
        market::buy_shares(user1, market_obj, true, 5_000_000, 0);
        timestamp::update_global_time_for_test_secs(4 * 60 * 60 * 24 * 7);

        // prices must always be 8 decimals
        let (price_yes, price_no) = market::prices(market_obj);
        assert!(is_equal_or_off_by_one(price_yes, 1_0000_0000));
        assert!(is_equal_or_off_by_one(price_no, 0));

        market::withdraw_liquidity(market_creator, market_obj, 100_000_000, false);
        market::sell_shares(user1, market_obj, true, primary_fungible_store::balance(signer::address_of(user1), metadata(ASSET_SYMBOL_YES)), 0);
        market::sell_shares(market_creator, market_obj, false, primary_fungible_store::balance(signer::address_of(market_creator), metadata(ASSET_SYMBOL_NO)), 0);

        assert!(primary_fungible_store::balance(signer::address_of(market_creator), coins_metadata) == 96_644_323);

        let (x, y, z) = market::fees(market_obj);
        assert!(x == 655_559);
        assert!(y == 894_449);
        assert!(z == 0);

        let user_balance = primary_fungible_store::balance(signer::address_of(user1), coins_metadata);
        let mc_balance = primary_fungible_store::balance(signer::address_of(market_creator), coins_metadata);
        assert!(x + y + z + user_balance + mc_balance == 200_000_000 - 1);

        market::collect_fees(market_creator, market_obj);

        let user_balance = primary_fungible_store::balance(signer::address_of(user1), coins_metadata);
        let mc_balance = primary_fungible_store::balance(signer::address_of(market_creator), coins_metadata);
        assert!((user_balance + mc_balance) == 200_000_000 - 1);

    }

    #[test(aptos_framework = @aptos_framework, panana = @panana, user1 = @user1, user2 = @user2, market_creator = @admin)]
    public fun test_buy_in_lp_fee(aptos_framework: &signer, panana: &signer, user1: &signer, user2: &signer, market_creator: &signer) {
        let (burn_ref, mint_ref) = initialize_for_test(aptos_framework);
        market::init_test(aptos_framework, panana);

        let aptos_coin_metadata = *coin::paired_metadata<AptosCoin>().borrow();

        let creator_tokens = coin::coin_to_fungible_asset(coin::mint(1000 * OCTAS_PER_APT, &mint_ref));
        aptos_account::deposit_fungible_assets(signer::address_of(market_creator), creator_tokens);
        let lp_tokens = coin::coin_to_fungible_asset(coin::mint(5000 * OCTAS_PER_APT, &mint_ref));
        aptos_account::deposit_fungible_assets(signer::address_of(user2), lp_tokens);

        market::create_market(
            market_creator,
            aptos_coin_metadata,
            string::utf8(b"Will Panana be big?"),
            string::utf8(b"Great question with an obvious answer"),
            string::utf8(b"Always resolves to yes"),
            vector[string::utf8(b"https://panana.com")],
            0,
            1000 * OCTAS_PER_APT,
            1000 * OCTAS_PER_APT,
            0,
            0,
            10_000,
            0,
            0,
            0,
            false,
            false
        );
        let market_obj_fee = market::market_by_id(0);
        let (lp_token, _) = market::get_lp_tokens(market_obj_fee);
        assert!(primary_fungible_store::balance (signer::address_of(market_creator),lp_token) == 1000 * OCTAS_PER_APT);

        let user_tokens = coin::coin_to_fungible_asset(coin::mint(5000 * OCTAS_PER_APT, &mint_ref));
        aptos_account::deposit_fungible_assets(signer::address_of(user1), user_tokens);

        coin::destroy_burn_cap(burn_ref);
        coin::destroy_mint_cap(mint_ref);

        market::buy_shares(user1, market_obj_fee, true, 1000 * OCTAS_PER_APT,0);
        market::add_liquidity(user2, market_obj_fee, 3000 * OCTAS_PER_APT, false);
        market::buy_shares(user1, market_obj_fee, true, 2000 * OCTAS_PER_APT, 0);
        market::withdraw_liquidity(user2, market_obj_fee, 1000 * OCTAS_PER_APT, false);
        market::buy_shares(user1, market_obj_fee, true, 1000 * OCTAS_PER_APT, 0);
        market::add_liquidity(user2, market_obj_fee, 2000 * OCTAS_PER_APT, false);
        market::buy_shares(user1, market_obj_fee, true, 1000 * OCTAS_PER_APT, 0);

        market::resolve_market(market_creator, market_obj_fee, metadata(ASSET_SYMBOL_YES));
        timestamp::update_global_time_for_test_secs(4 * 60 * 60 * 24 * 7);

        market::withdraw_liquidity(market_creator, market_obj_fee, 1000 * OCTAS_PER_APT, false);
        market::withdraw_liquidity(user2, market_obj_fee, primary_fungible_store::balance(signer::address_of(user2), lp_token), false);
        timestamp::update_global_time_for_test_secs(5 * 60 * 60 * 24 * 7);
        // market::claim_liquidity_withdrawal_requests(market_creator);
        // market::claim_liquidity_withdrawal_requests(user2);

        let creator_balance = primary_fungible_store::balance(signer::address_of(market_creator), aptos_coin_metadata);
        assert!(creator_balance == 3033_3333_3000);
        let lp_balance = primary_fungible_store::balance(signer::address_of(user2), aptos_coin_metadata);
        assert!(lp_balance == 7966_6666_4000);
        let dust_balance = primary_fungible_store::balance(object_address(&market_obj_fee), aptos_coin_metadata);
        assert!(dust_balance == 0);
    }

    #[test(aptos_framework = @aptos_framework, panana = @panana, user1 = @user1, user2 = @user2, market_creator = @admin)]
    public fun test_buy_lp_fee(aptos_framework: &signer, panana: &signer, user1: &signer, user2: &signer, market_creator: &signer) {
        let (burn_ref, mint_ref) = initialize_for_test(aptos_framework);
        market::init_test(aptos_framework, panana);

        let aptos_coin_metadata = *coin::paired_metadata<AptosCoin>().borrow();

        let creator_tokens = coin::coin_to_fungible_asset(coin::mint(1000 * OCTAS_PER_APT, &mint_ref));
        aptos_account::deposit_fungible_assets(signer::address_of(market_creator), creator_tokens);
        let lp_tokens = coin::coin_to_fungible_asset(coin::mint(5000 * OCTAS_PER_APT, &mint_ref));
        aptos_account::deposit_fungible_assets(signer::address_of(user2), lp_tokens);

        market::create_market(
            market_creator,
            aptos_coin_metadata,
            string::utf8(b"Will Panana be big?"),
            string::utf8(b"Great question with an obvious answer"),
            string::utf8(b"Always resolves to yes"),
            vector[string::utf8(b"https://panana.com")],
            0,
            1000 * OCTAS_PER_APT,
            1000 * OCTAS_PER_APT,
            0,
            0,
            300,
            0,
            0,
            0,
            false,
            false
        );
        let market_obj_fee = market::market_by_id(0);
        let (lp_token, _) = market::get_lp_tokens(market_obj_fee);
        assert!(primary_fungible_store::balance (signer::address_of(market_creator), lp_token) == 1000 * OCTAS_PER_APT);

        let user_tokens = coin::coin_to_fungible_asset(coin::mint(5000 * OCTAS_PER_APT, &mint_ref));
        aptos_account::deposit_fungible_assets(signer::address_of(user1), user_tokens);

        coin::destroy_burn_cap(burn_ref);
        coin::destroy_mint_cap(mint_ref);

        market::buy_shares(user1, market_obj_fee, true, 1000 * OCTAS_PER_APT,0);
        assert!(lp_fees(market_obj_fee, signer::address_of(market_creator)) == 30_0000_0000);

        market::add_liquidity(user2, market_obj_fee, 3000 * OCTAS_PER_APT, false);
        market::buy_shares(user1, market_obj_fee, true, 2000 * OCTAS_PER_APT,0);
        assert!(lp_fees(market_obj_fee, signer::address_of(market_creator)) == 45_0000_0000);
        assert!(lp_fees(market_obj_fee, signer::address_of(user2)) == 45_0000_0000);

        let (lp_meta, lps_meta) = market::get_lp_tokens(market_obj_fee);
        let user2_lp_balance = primary_fungible_store::balance(signer::address_of(user2), lp_meta);
        market::withdraw_liquidity(user2, market_obj_fee, user2_lp_balance / 3, false);


        market::buy_shares(user1, market_obj_fee, true, 1000 * OCTAS_PER_APT,0);
        assert!(lp_fees(market_obj_fee, signer::address_of(market_creator)) == 54_9999_9000);
        assert!(lp_fees(market_obj_fee, signer::address_of(user2)) == 49_9999_8000);


        market::add_liquidity(user2, market_obj_fee, 2000 * OCTAS_PER_APT, false);
        market::buy_shares(user1, market_obj_fee, true, 1000 * OCTAS_PER_APT,0);

        assert!(lp_fees(market_obj_fee, signer::address_of(market_creator)) == 60_9999_8000);
        assert!(lp_fees(market_obj_fee, signer::address_of(user2)) == 73_9999_2000);

        market::resolve_market(market_creator, market_obj_fee, metadata(ASSET_SYMBOL_YES));
        timestamp::update_global_time_for_test_secs(4 * 60 * 60 * 24 * 7);

        assert!(lp_fees(market_obj_fee, signer::address_of(market_creator)) == 60_9999_8000);
        assert!(lp_fees(market_obj_fee, signer::address_of(user2)) == 73_9999_2000);
    }

    #[test(aptos_framework = @aptos_framework, panana = @panana, user1 = @user1, user2 = @user2, market_creator = @admin)]
    public fun test_sell_lp_fee(aptos_framework: &signer, panana: &signer, user1: &signer, user2: &signer, market_creator: &signer) {
        let (burn_ref, mint_ref) = initialize_for_test(aptos_framework);
        market::init_test(aptos_framework, panana);

        let aptos_coin_metadata = *coin::paired_metadata<AptosCoin>().borrow();

        let creator_tokens = coin::coin_to_fungible_asset(coin::mint(1000 * OCTAS_PER_APT, &mint_ref));
        aptos_account::deposit_fungible_assets(signer::address_of(market_creator), creator_tokens);
        let lp_tokens = coin::coin_to_fungible_asset(coin::mint(5000 * OCTAS_PER_APT, &mint_ref));
        aptos_account::deposit_fungible_assets(signer::address_of(user2), lp_tokens);

        market::create_market(
            market_creator,
            aptos_coin_metadata,
            string::utf8(b"Will Panana be big?"),
            string::utf8(b"Great question with an obvious answer"),
            string::utf8(b"Always resolves to yes"),
            vector[string::utf8(b"https://panana.com")],
            0,
            1000 * OCTAS_PER_APT,
            1000 * OCTAS_PER_APT,
            0,
            0,
            0,
            0,
            0,
            300,
            false,
            false
        );
        let market_obj_fee = market::market_by_id(0);
        let (lp_meta, lps_meta) = market::get_lp_tokens(market_obj_fee);
        assert!(primary_fungible_store::balance (signer::address_of(market_creator),lp_meta) == 1000 * OCTAS_PER_APT);

        let user_tokens = coin::coin_to_fungible_asset(coin::mint(5000 * OCTAS_PER_APT, &mint_ref));
        aptos_account::deposit_fungible_assets(signer::address_of(user1), user_tokens);

        coin::destroy_burn_cap(burn_ref);
        coin::destroy_mint_cap(mint_ref);

        market::buy_shares(user1, market_obj_fee, true, 1000 * OCTAS_PER_APT,0);

        market::add_liquidity(user2, market_obj_fee, 3000 * OCTAS_PER_APT, false);
        market::buy_shares(user1, market_obj_fee, true, 2000 * OCTAS_PER_APT,0);

        let user2_lp_balance = primary_fungible_store::balance(signer::address_of(user2), lp_meta);
        market::withdraw_liquidity(user2, market_obj_fee, user2_lp_balance / 3, false);

        market::buy_shares(user1, market_obj_fee, true, 1000 * OCTAS_PER_APT,0);

        market::add_liquidity(user2, market_obj_fee, 2000 * OCTAS_PER_APT, false);
        market::buy_shares(user1, market_obj_fee, true, 1000 * OCTAS_PER_APT,0);

        assert!(lp_fees(market_obj_fee, signer::address_of(market_creator)) == 0);
        assert!(lp_fees(market_obj_fee, signer::address_of(user2)) == 0);

        market::resolve_market(market_creator, market_obj_fee, metadata(ASSET_SYMBOL_YES));
        timestamp::update_global_time_for_test_secs(4 * 60 * 60 * 24 * 7);

        market::sell_shares(user1, market_obj_fee, true, 1000 * OCTAS_PER_APT, 0);

                assert!(lp_fees(market_obj_fee, signer::address_of(market_creator)) == 60_6838_5000);
                assert!(lp_fees(market_obj_fee, signer::address_of(user2)) == 242_7354_0000);

        market::withdraw_liquidity(market_creator, market_obj_fee, primary_fungible_store::balance(signer::address_of(market_creator), lp_meta), false);
        market::withdraw_liquidity(user2, market_obj_fee, primary_fungible_store::balance(signer::address_of(user2), lp_meta), false);

        market::sell_shares(user2, market_obj_fee, true, primary_fungible_store::balance(signer::address_of(user2), metadata(ASSET_SYMBOL_YES)), 0);
        market::sell_shares(user1, market_obj_fee, true, primary_fungible_store::balance(signer::address_of(user1), metadata(ASSET_SYMBOL_YES)), 0);

        let dust_balance = primary_fungible_store::balance(object_address(&market_obj_fee), aptos_coin_metadata);
        assert!(dust_balance == 1);
    }

    #[test(aptos_framework = @aptos_framework, panana = @panana, user1 = @user1, user2 = @user2, market_creator = @admin)]
    public fun test_sell_dissolved_fee(aptos_framework: &signer, panana: &signer, user1: &signer, user2: &signer, market_creator: &signer) {
        let (burn_ref, mint_ref) = initialize_for_test(aptos_framework);
        market::init_test(aptos_framework, panana);

        let aptos_coin_metadata = *coin::paired_metadata<AptosCoin>().borrow();

        let creator_tokens = coin::coin_to_fungible_asset(coin::mint(1000 * OCTAS_PER_APT, &mint_ref));
        aptos_account::deposit_fungible_assets(signer::address_of(market_creator), creator_tokens);

        market::create_market(
            market_creator,
            aptos_coin_metadata,
            string::utf8(b"Will Panana be big?"),
            string::utf8(b"Great question with an obvious answer"),
            string::utf8(b"Always resolves to yes"),
            vector[string::utf8(b"https://panana.com")],
            0,
            1000 * OCTAS_PER_APT,
            1000 * OCTAS_PER_APT,
            0,
            0,
            0,
            0,
            0,
            300,
            false,
            false
        );
        let market_obj_fee = market::market_by_id(0);
        let (lp_meta, lps_meta) = market::get_lp_tokens(market_obj_fee);
        assert!(primary_fungible_store::balance (signer::address_of(market_creator), lp_meta) == 1000 * OCTAS_PER_APT);

        let user_tokens = coin::coin_to_fungible_asset(coin::mint(1000 * OCTAS_PER_APT, &mint_ref));
        aptos_account::deposit_fungible_assets(signer::address_of(user1), user_tokens);

        coin::destroy_burn_cap(burn_ref);
        coin::destroy_mint_cap(mint_ref);

        market::buy_shares(user1, market_obj_fee, true, 1000 * OCTAS_PER_APT,0);

        market::dissolve_market(market_creator, market_obj_fee);

        let yes_balance = primary_fungible_store::balance(signer::address_of(user1), metadata(ASSET_SYMBOL_YES));
        let (p_y, p_n) = market::prices(market_obj_fee);
        market::sell_shares(user1, market_obj_fee, true, yes_balance, 0);
        let (p2_y, p2_n) = market::prices(market_obj_fee);
        assert!(p_y == p2_y);
        assert!(p_n == p2_n);

        let expected_balance = math64::mul_div((yes_balance * p_y), 9_700, 10_000 * OCTAS_PER_APT);
        assert!(is_equal_or_off_by_one(primary_fungible_store::balance(signer::address_of(user1), aptos_coin_metadata), expected_balance)); // 1200 - 36 fee = 1164

        assert!(primary_fungible_store::balance(signer::address_of(market_creator), aptos_coin_metadata) == 0);
        market::withdraw_liquidity(market_creator, market_obj_fee, 1000 * OCTAS_PER_APT, false);

        // market::claim_liquidity_withdrawal_requests(market_creator);
        let market_creator_balance = primary_fungible_store::balance(signer::address_of(market_creator), aptos_coin_metadata);
        // 500 from LP tokens, 45 from LP Fees (36 from yes sell, 9 from lp "No" token sale)
        assert!(market_creator_balance == 545_0000_0000);
        market::sell_shares(market_creator, market_obj_fee, false, 1500 * OCTAS_PER_APT, 0);
        let market_creator_balance = primary_fungible_store::balance(signer::address_of(market_creator), aptos_coin_metadata);
        assert!(market_creator_balance == 836_0000_0000); // 500 from LP tokens, 36 from LP Fees, 300 from no shares selling minus 9 for fees for no share selling

        let vault_balance = primary_fungible_store::balance(object_address(&market_obj_fee), aptos_coin_metadata);
        assert!(vault_balance == 0);
    }

    #[test(aptos_framework = @aptos_framework, panana = @panana, user1 = @user1, user2 = @user2, market_creator = @admin)]
    public fun test_sell_dissolved_fee_buy_sell(aptos_framework: &signer, panana: &signer, user1: &signer, user2: &signer, market_creator: &signer) {
        let (burn_ref, mint_ref) = initialize_for_test(aptos_framework);
        market::init_test(aptos_framework, panana);

        let aptos_coin_metadata = *coin::paired_metadata<AptosCoin>().borrow();

        let creator_tokens = coin::coin_to_fungible_asset(coin::mint(1000 * OCTAS_PER_APT, &mint_ref));
        aptos_account::deposit_fungible_assets(signer::address_of(market_creator), creator_tokens);

        market::create_market(
            market_creator,
            aptos_coin_metadata,
            string::utf8(b"Will Panana be big?"),
            string::utf8(b"Great question with an obvious answer"),
            string::utf8(b"Always resolves to yes"),
            vector[string::utf8(b"https://panana.com")],
            0,
            1000 * OCTAS_PER_APT,
            1000 * OCTAS_PER_APT,
            0,
            0,
            0,
            0,
            0,
            300,
            false,
            false
        );
        let market_obj_fee = market::market_by_id(0);
        let (lp_meta, lps_meta) = market::get_lp_tokens(market_obj_fee);
        assert!(primary_fungible_store::balance (signer::address_of(market_creator), lp_meta) == 1000 * OCTAS_PER_APT);

        let user_tokens = coin::coin_to_fungible_asset(coin::mint(5000 * OCTAS_PER_APT, &mint_ref));
        aptos_account::deposit_fungible_assets(signer::address_of(user1), user_tokens);

        coin::destroy_burn_cap(burn_ref);
        coin::destroy_mint_cap(mint_ref);

        market::buy_shares(user1, market_obj_fee, true, 1000 * OCTAS_PER_APT,0);
        market::buy_shares(user1, market_obj_fee, false, 1000 * OCTAS_PER_APT,0);
        market::sell_shares(user1, market_obj_fee, true, 300 * OCTAS_PER_APT, 0);
        market::buy_shares(user1, market_obj_fee, false, 500 * OCTAS_PER_APT,0);
        market::buy_shares(user1, market_obj_fee, true, 300 * OCTAS_PER_APT,0);
        market::sell_shares(user1, market_obj_fee, false, 200 * OCTAS_PER_APT, 0);
        market::sell_shares(user1, market_obj_fee, true, 300 * OCTAS_PER_APT, 0);

        market::dissolve_market(market_creator, market_obj_fee);

        let yes_balance = primary_fungible_store::balance(signer::address_of(user1), metadata(ASSET_SYMBOL_YES));
        let (p_y, p_n) = market::prices(market_obj_fee);
        market::sell_shares(user1, market_obj_fee, true, yes_balance / 2, 0);
        let (p2_y, p2_n) = market::prices(market_obj_fee);
        assert!(p_y == p2_y);
        assert!(p_n == p2_n);

        // let expected_balance = math64::mul_div((yes_balance * p_y), 9_700, 10_000 * OCTAS_PER_APT);
        // assert!(is_equal_or_off_by_one(primary_fungible_store::balance(signer::address_of(user1), aptos_coin_metadata), expected_balance)); // 1200 - 36 fee = 1164

        assert!(primary_fungible_store::balance(signer::address_of(market_creator), aptos_coin_metadata) == 0);
        market::withdraw_liquidity(market_creator, market_obj_fee, 1000 * OCTAS_PER_APT, false);

        market::sell_shares(user1, market_obj_fee, true, primary_fungible_store::balance(signer::address_of(user1), metadata(ASSET_SYMBOL_YES)), 0);
        market::sell_shares(user1, market_obj_fee, false, primary_fungible_store::balance(signer::address_of(user1), metadata(ASSET_SYMBOL_NO)), 0);
        market::sell_shares(market_creator, market_obj_fee, true, primary_fungible_store::balance(signer::address_of(market_creator), metadata(ASSET_SYMBOL_YES)), 0);

        let vault_balance = primary_fungible_store::balance(object_address(&market_obj_fee), aptos_coin_metadata);
        assert!(vault_balance == 2685);
    }

    #[test(aptos_framework = @aptos_framework, panana = @panana, user1 = @user1, user2 = @user2, market_creator = @admin)]
    public fun test_sell_dissolved_fee_synth(aptos_framework: &signer, panana: &signer, user1: &signer, user2: &signer, market_creator: &signer) {
        let (burn_ref, mint_ref) = initialize_for_test(aptos_framework);
        market::init_test(aptos_framework, panana);

        let aptos_coin_metadata = *coin::paired_metadata<AptosCoin>().borrow();

        let creator_tokens = coin::coin_to_fungible_asset(coin::mint(1000 * OCTAS_PER_APT, &mint_ref));
        aptos_account::deposit_fungible_assets(signer::address_of(market_creator), creator_tokens);

        market::create_market(
            market_creator,
            aptos_coin_metadata,
            string::utf8(b"Will Panana be big?"),
            string::utf8(b"Great question with an obvious answer"),
            string::utf8(b"Always resolves to yes"),
            vector[string::utf8(b"https://panana.com")],
            0,
            1000 * OCTAS_PER_APT,
            1000 * OCTAS_PER_APT,
            0,
            0,
            0,
            0,
            0,
            300,
            false,
            true
        );
        let market_obj_fee = market::market_by_id(0);
        let (lp_meta, lps_meta) = market::get_lp_tokens(market_obj_fee);
        assert!(primary_fungible_store::balance (signer::address_of(market_creator), lps_meta) == 1000 * OCTAS_PER_APT);

        let user_tokens = coin::coin_to_fungible_asset(coin::mint(1000 * OCTAS_PER_APT, &mint_ref));
        aptos_account::deposit_fungible_assets(signer::address_of(user1), user_tokens);

        coin::destroy_burn_cap(burn_ref);
        coin::destroy_mint_cap(mint_ref);

        market::buy_shares(user1, market_obj_fee, true, 1000 * OCTAS_PER_APT,0);

        market::dissolve_market(market_creator, market_obj_fee);
        market::withdraw_liquidity(market_creator, market_obj_fee, 1000 * OCTAS_PER_APT, true);

        let yes_balance = primary_fungible_store::balance(signer::address_of(user1), metadata(ASSET_SYMBOL_YES));
        let (p_y, p_n) = market::prices(market_obj_fee);
        market::sell_shares(user1, market_obj_fee, true, yes_balance, 0);
        let (p2_y, p2_n) = market::prices(market_obj_fee);
        assert!(p_y == p2_y);
        assert!(p_n == p2_n);

        let expected_balance = math64::mul_div((yes_balance * p_y), 9_700, 10_000 * OCTAS_PER_APT);
        assert!(is_equal_or_off_by_one(primary_fungible_store::balance(signer::address_of(user1), aptos_coin_metadata), expected_balance)); // 1200 - 36 fee = 1164


        // market::claim_liquidity_withdrawal_requests(market_creator);
        let market_creator_balance = primary_fungible_store::balance(signer::address_of(market_creator), aptos_coin_metadata);
        // 500 from LP tokens, 45 from LP Fees (36 from yes sell, 9 from lp "No" token sale)
        assert!(market_creator_balance == 545_0000_0000);
        market::sell_shares(market_creator, market_obj_fee, false, 1500 * OCTAS_PER_APT, 0);
        let market_creator_balance = primary_fungible_store::balance(signer::address_of(market_creator), aptos_coin_metadata);
        assert!(market_creator_balance == 836_0000_0000); // 500 from LP tokens, 36 from LP Fees, 300 from no shares selling minus 9 for fees for no share selling

        let vault_balance = primary_fungible_store::balance(object_address(&market_obj_fee), aptos_coin_metadata);
        assert!(vault_balance == 0);
    }

    #[test(aptos_framework = @aptos_framework, panana = @panana, user1 = @user1, user2 = @user2, market_creator = @admin)]
    public fun test_sell_resolution_lp_shares_should_result_in_empty_vault(aptos_framework: &signer, panana: &signer, user1: &signer, user2: &signer, market_creator: &signer) {
        let (burn_ref, mint_ref) = initialize_for_test(aptos_framework);
        market::init_test(aptos_framework, panana);

        let aptos_coin_metadata = *coin::paired_metadata<AptosCoin>().borrow();

        let creator_tokens = coin::coin_to_fungible_asset(coin::mint(1000 * OCTAS_PER_APT, &mint_ref));
        aptos_account::deposit_fungible_assets(signer::address_of(market_creator), creator_tokens);

        market::create_market(
            market_creator,
            aptos_coin_metadata,
            string::utf8(b"Will Panana be big?"),
            string::utf8(b"Great question with an obvious answer"),
            string::utf8(b"Always resolves to yes"),
            vector[string::utf8(b"https://panana.com")],
            0,
            1000 * OCTAS_PER_APT,
            1000 * OCTAS_PER_APT,
            0,
            0,
            0,
            0,
            0,
            0,
            false,
            false
        );
        let market_obj_fee = market::market_by_id(0);
        let (lp_meta, lps_meta) = market::get_lp_tokens(market_obj_fee);
        assert!(primary_fungible_store::balance (signer::address_of(market_creator), lp_meta) == 1000 * OCTAS_PER_APT);

        let user_tokens = coin::coin_to_fungible_asset(coin::mint(1000 * OCTAS_PER_APT, &mint_ref));
        aptos_account::deposit_fungible_assets(signer::address_of(user1), user_tokens);

        coin::destroy_burn_cap(burn_ref);
        coin::destroy_mint_cap(mint_ref);

        market::buy_shares(user1, market_obj_fee, true, 1000 * OCTAS_PER_APT,0);

        market::resolve_market(market_creator, market_obj_fee, metadata(ASSET_SYMBOL_NO));
        timestamp::update_global_time_for_test_secs(4 * 60 * 60 * 24 * 7);


        assert!(primary_fungible_store::balance(signer::address_of(user1), aptos_coin_metadata) == 0);

        assert!(primary_fungible_store::balance(signer::address_of(market_creator), aptos_coin_metadata) == 0);
        market::withdraw_liquidity(market_creator, market_obj_fee, 1000 * OCTAS_PER_APT, false);

        // market::claim_liquidity_withdrawal_requests(market_creator);
        let market_creator_balance = primary_fungible_store::balance(signer::address_of(market_creator), aptos_coin_metadata);
                assert!(market_creator_balance == 2000_0000_0000);

        let vault_balance = primary_fungible_store::balance(object_address(&market_obj_fee), aptos_coin_metadata);
        assert!(vault_balance == 0);
    }

    #[expected_failure(abort_code = market::E_INVALID_OUTCOME)]
    #[test(aptos_framework = @aptos_framework, panana = @panana, user1 = @user1, user2 = @user2, market_creator = @admin)]
    public fun test_resolve_market_invalid_outcome_token(aptos_framework: &signer, panana: &signer, user1: &signer, user2: &signer, market_creator: &signer) {
        let (burn_ref, mint_ref) = initialize_for_test(aptos_framework);
        market::init_test(aptos_framework, panana);

        let aptos_coin_metadata = *coin::paired_metadata<AptosCoin>().borrow();

        market::create_market(
            market_creator,
            aptos_coin_metadata,
            string::utf8(b"Will Panana be big?"),
            string::utf8(b"Great question with an obvious answer"),
            string::utf8(b"Always resolves to yes"),
            vector[string::utf8(b"https://panana.com")],
            0,
            1000 * OCTAS_PER_APT,
            1000 * OCTAS_PER_APT,
            0,
            0,
            0,
            0,
            0,
            0,
            false,
            true
        );
        let market_obj_fee = market::market_by_id(0);

        coin::destroy_burn_cap(burn_ref);
        coin::destroy_mint_cap(mint_ref);

        market::resolve_market(market_creator, market_obj_fee, aptos_coin_metadata);
    }

    #[test(aptos_framework = @aptos_framework, panana = @panana, user1 = @user1, user2 = @user2, market_creator = @admin)]
    public fun test_sell_after_resolution(aptos_framework: &signer, panana: &signer, user1: &signer, user2: &signer, market_creator: &signer) {
        let (burn_ref, mint_ref) = initialize_for_test(aptos_framework);
        market::init_test(aptos_framework, panana);

        let aptos_coin_metadata = *coin::paired_metadata<AptosCoin>().borrow();

        let creator_tokens = coin::coin_to_fungible_asset(coin::mint(1000 * OCTAS_PER_APT, &mint_ref));
        aptos_account::deposit_fungible_assets(signer::address_of(market_creator), creator_tokens);
        let lp_tokens = coin::coin_to_fungible_asset(coin::mint(5000 * OCTAS_PER_APT, &mint_ref));
        aptos_account::deposit_fungible_assets(signer::address_of(user2), lp_tokens);

        market::create_market(
            market_creator,
            aptos_coin_metadata,
            string::utf8(b"Will Panana be big?"),
            string::utf8(b"Great question with an obvious answer"),
            string::utf8(b"Always resolves to yes"),
            vector[string::utf8(b"https://panana.com")],
            0,
            1000 * OCTAS_PER_APT,
            1000 * OCTAS_PER_APT,
            0,
            0,
            0,
            0,
            0,
            0,
            false,
            false
        );
        let market_obj_fee = market::market_by_id(0);
        let (lp_meta, lps_meta) = market::get_lp_tokens(market_obj_fee);
        assert!(primary_fungible_store::balance (signer::address_of(market_creator),lp_meta) == 1000 * OCTAS_PER_APT);

        let user_tokens = coin::coin_to_fungible_asset(coin::mint(5000 * OCTAS_PER_APT, &mint_ref));
        aptos_account::deposit_fungible_assets(signer::address_of(user1), user_tokens);

        coin::destroy_burn_cap(burn_ref);
        coin::destroy_mint_cap(mint_ref);

        market::buy_shares(user1, market_obj_fee, true, 1000 * OCTAS_PER_APT,0);

        market::add_liquidity(user2, market_obj_fee, 3000 * OCTAS_PER_APT, false);
        market::buy_shares(user1, market_obj_fee, true, 2000 * OCTAS_PER_APT,0);

        let user2_lp_balance = primary_fungible_store::balance(signer::address_of(user2), lp_meta);
        market::withdraw_liquidity(user2, market_obj_fee, user2_lp_balance / 3, false);


        market::buy_shares(user1, market_obj_fee, true, 1000 * OCTAS_PER_APT,0);
        market::add_liquidity(user2, market_obj_fee, 2000 * OCTAS_PER_APT, false);
        market::buy_shares(user1, market_obj_fee, true, 1000 * OCTAS_PER_APT,0);

        market::resolve_market(market_creator, market_obj_fee, metadata(ASSET_SYMBOL_YES));
        timestamp::update_global_time_for_test_secs(4 * 60 * 60 * 24 * 7);

        market::sell_shares(user1, market_obj_fee, true, 1000 * OCTAS_PER_APT, 0);

        market::withdraw_liquidity(market_creator, market_obj_fee, primary_fungible_store::balance(signer::address_of(market_creator), lp_meta), false);
        market::withdraw_liquidity(user2, market_obj_fee, primary_fungible_store::balance(signer::address_of(user2), lp_meta), false);

        market::sell_shares(user2, market_obj_fee, true, primary_fungible_store::balance(signer::address_of(user2), metadata(ASSET_SYMBOL_YES)), 0);
        market::sell_shares(user1, market_obj_fee, true, primary_fungible_store::balance(signer::address_of(user1), metadata(ASSET_SYMBOL_YES)), 0);
        let (_, _, lp_fee) = market::fees(market_obj_fee);
        assert!(lp_fee == 0);

        let dust_balance = primary_fungible_store::balance(object_address(&market_obj_fee), aptos_coin_metadata);
        assert!(dust_balance == 2);
    }


    #[expected_failure(abort_code = market::E_UNAUTHORIZED)]
    #[test(aptos_framework = @aptos_framework, panana = @panana, user1 = @user1, user2 = @user2, market_creator = @admin)]
    public fun test_add_synthetic_liquidity_from_user(aptos_framework: &signer, panana: &signer, user1: &signer, user2: &signer, market_creator: &signer) {
        let (burn_ref, mint_ref) = initialize_for_test(aptos_framework);
        market::init_test(aptos_framework, panana);

        let aptos_coin_metadata = *coin::paired_metadata<AptosCoin>().borrow();

        market::create_market(
            market_creator,
            aptos_coin_metadata,
            string::utf8(b"Will Panana be big?"),
            string::utf8(b"Great question with an obvious answer"),
            string::utf8(b"Always resolves to yes"),
            vector[string::utf8(b"https://panana.com")],
            0,
            1000 * OCTAS_PER_APT,
            1000 * OCTAS_PER_APT,
            0,
            10_000,
            0,
            0,
            0,
            0,
            false,
            true
        );
        let market_obj_fee = market::market_by_id(0);

        coin::destroy_burn_cap(burn_ref);
        coin::destroy_mint_cap(mint_ref);

        market::add_liquidity(user2, market_obj_fee, 3000 * OCTAS_PER_APT, true);
    }

    #[test(aptos_framework = @aptos_framework, panana = @panana, user1 = @user1, user2 = @user2, market_creator = @admin)]
    public fun test_synthetic_and_real_liquidity(aptos_framework: &signer, panana: &signer, user1: &signer, user2: &signer, market_creator: &signer) {
        let (burn_ref, mint_ref) = initialize_for_test(aptos_framework);
        market::init_test(aptos_framework, panana);

        let aptos_coin_metadata = *coin::paired_metadata<AptosCoin>().borrow();

        let lp_tokens = coin::coin_to_fungible_asset(coin::mint(5000 * OCTAS_PER_APT, &mint_ref));
        aptos_account::deposit_fungible_assets(signer::address_of(user2), lp_tokens);

        let lp_tokens_creator = coin::coin_to_fungible_asset(coin::mint(4000 * OCTAS_PER_APT, &mint_ref));
        aptos_account::deposit_fungible_assets(signer::address_of(market_creator), lp_tokens_creator);

        market::create_market(
            market_creator,
            aptos_coin_metadata,
            string::utf8(b"Will Panana be big?"),
            string::utf8(b"Great question with an obvious answer"),
            string::utf8(b"Always resolves to yes"),
            vector[string::utf8(b"https://panana.com")],
            0,
            1000 * OCTAS_PER_APT,
            1000 * OCTAS_PER_APT,
            0,
            0,
            100,
            0,
            0,
            0,
            false,
            true
        );
        let market_obj_fee = market::market_by_id(0);
        let (lp_meta, lps_meta) = market::get_lp_tokens(market_obj_fee);
        assert!(primary_fungible_store::balance (signer::address_of(market_creator),lps_meta) == 1000 * OCTAS_PER_APT);

        let user_tokens = coin::coin_to_fungible_asset(coin::mint(5000 * OCTAS_PER_APT, &mint_ref));
        aptos_account::deposit_fungible_assets(signer::address_of(user1), user_tokens);

        coin::destroy_burn_cap(burn_ref);
        coin::destroy_mint_cap(mint_ref);

        market::buy_shares(user1, market_obj_fee, true, 1000 * OCTAS_PER_APT,0);
        market::add_liquidity(user2, market_obj_fee, 3000 * OCTAS_PER_APT, false);
        market::add_liquidity(market_creator, market_obj_fee, 3000 * OCTAS_PER_APT, false);
        market::buy_shares(user1, market_obj_fee, true, 2000 * OCTAS_PER_APT,0);
        market::withdraw_liquidity(user2, market_obj_fee, 1000 * OCTAS_PER_APT, false);
        market::buy_shares(user1, market_obj_fee, true, 1000 * OCTAS_PER_APT,0);
        market::add_liquidity(user2, market_obj_fee, 2000 * OCTAS_PER_APT, false);
        market::buy_shares(user1, market_obj_fee, true, 1000 * OCTAS_PER_APT,0);


        market::resolve_market(market_creator, market_obj_fee, metadata(ASSET_SYMBOL_YES));
        timestamp::update_global_time_for_test_secs(4 * 60 * 60 * 24 * 7);


        let y = 1000 * OCTAS_PER_APT;
        market::withdraw_liquidity(market_creator, market_obj_fee, y, true);
        market::withdraw_liquidity(market_creator, market_obj_fee, primary_fungible_store::balance(signer::address_of(market_creator), lp_meta), false);
        market::withdraw_liquidity(user2, market_obj_fee, primary_fungible_store::balance(signer::address_of(user2), lp_meta), false);

        let creator_balance = primary_fungible_store::balance(signer::address_of(market_creator), aptos_coin_metadata);
        assert!(creator_balance == 840_0055_7012);
        let lp_balance = primary_fungible_store::balance(signer::address_of(user2), aptos_coin_metadata);
        assert!(lp_balance == 813_7101_2480);

        market::sell_shares(user1, market_obj_fee, true, primary_fungible_store::balance(signer::address_of(user1), metadata(ASSET_SYMBOL_YES)), 0);
        market::sell_shares(user2, market_obj_fee, true, primary_fungible_store::balance(signer::address_of(user2), metadata(ASSET_SYMBOL_YES)), 0);

        market::sell_shares(market_creator, market_obj_fee, true, primary_fungible_store::balance(signer::address_of(market_creator), metadata(ASSET_SYMBOL_YES)), 0);

        market::sell_shares(user2, market_obj_fee, false, primary_fungible_store::balance(signer::address_of(user2), metadata(ASSET_SYMBOL_NO)), 0);
        market::sell_shares(market_creator, market_obj_fee, false, primary_fungible_store::balance(signer::address_of(market_creator), metadata(ASSET_SYMBOL_NO)), 0);

        let dust_balance = primary_fungible_store::balance(object_address(&market_obj_fee), aptos_coin_metadata);
        assert!(dust_balance == 5);
    }


    #[test(aptos_framework = @aptos_framework, panana = @panana, user1 = @user1, user2 = @user2, market_creator = @admin)]
    public fun test_liq_change_many_buy_sell_liq(aptos_framework: &signer, panana: &signer, user1: &signer, user2: &signer, market_creator: &signer) {
        let (burn_ref, mint_ref) = initialize_for_test(aptos_framework);
        market::init_test(aptos_framework, panana);

        let aptos_coin_metadata = *coin::paired_metadata<AptosCoin>().borrow();

        let apot_tokens_user = coin::coin_to_fungible_asset(coin::mint(1000 * OCTAS_PER_APT, &mint_ref));
        aptos_account::deposit_fungible_assets(signer::address_of(user2), apot_tokens_user);

        let apt_tokens_creator = coin::coin_to_fungible_asset(coin::mint(2000 * OCTAS_PER_APT, &mint_ref));
        aptos_account::deposit_fungible_assets(signer::address_of(market_creator), apt_tokens_creator);

        let user_tokens = coin::coin_to_fungible_asset(coin::mint(5000 * OCTAS_PER_APT, &mint_ref));
        aptos_account::deposit_fungible_assets(signer::address_of(user1), user_tokens);

        market::create_market(
            market_creator,
            aptos_coin_metadata,
            string::utf8(b"Will Panana be big?"),
            string::utf8(b"Great question with an obvious answer"),
            string::utf8(b"Always resolves to yes"),
            vector[string::utf8(b"https://panana.com")],
            0,
            100 * OCTAS_PER_APT,
            1000 * OCTAS_PER_APT,
            0,
            0,
            0,
            0,
            0,
            0,
            false,
            false
        );
        let market_obj_fee = market::market_by_id(0);
        let (lp_meta, lps_meta) = market::get_lp_tokens(market_obj_fee);

        coin::destroy_burn_cap(burn_ref);
        coin::destroy_mint_cap(mint_ref);

        market::buy_shares(user1, market_obj_fee, true, 1000 * OCTAS_PER_APT,0);
        market::add_liquidity(user2, market_obj_fee, 1000 * OCTAS_PER_APT, false);

        market::add_liquidity(market_creator, market_obj_fee, 1000 * OCTAS_PER_APT, false);

        market::withdraw_liquidity(user2, market_obj_fee, 500 * OCTAS_PER_APT, false);


        // market::sell_shares(user1, market_obj_fee, true, 500 * OCTAS_PER_APT, 0);

        market::withdraw_liquidity(market_creator, market_obj_fee, 500 * OCTAS_PER_APT, false);
        // market::sell_shares(user1, market_obj_fee, false, 100 * OCTAS_PER_APT, 0);
        // market::buy_shares(user1, market_obj_fee, true, 1000 * OCTAS_PER_APT,0);
        //
        // market::withdraw_liquidity(market_creator, market_obj_fee, primary_fungible_store::balance(signer::address_of(market_creator), lp_meta) / 3, false);
        // market::add_liquidity(user2, market_obj_fee, false, 1000 * OCTAS_PER_APT);
        // TODO: sell shares don't trigger Fee payout for LP

        market::resolve_market(market_creator, market_obj_fee, metadata(ASSET_SYMBOL_NO));
        timestamp::update_global_time_for_test_secs(4 * 60 * 60 * 24 * 7);

        market::withdraw_liquidity(market_creator, market_obj_fee, primary_fungible_store::balance(signer::address_of(market_creator), lp_meta), false);

        market::sell_shares(user1, market_obj_fee, true, primary_fungible_store::balance(signer::address_of(user1), metadata(ASSET_SYMBOL_YES)), 0);
        market::sell_shares(user2, market_obj_fee, true, primary_fungible_store::balance(signer::address_of(user2), metadata(ASSET_SYMBOL_YES)), 0);
        market::sell_shares(user2, market_obj_fee, false, primary_fungible_store::balance(signer::address_of(user2), metadata(ASSET_SYMBOL_NO)), 0);
        // Following is error:
        market::sell_shares(market_creator, market_obj_fee, true, primary_fungible_store::balance(signer::address_of(market_creator), metadata(ASSET_SYMBOL_YES)), 0);
        market::sell_shares(market_creator, market_obj_fee, false, primary_fungible_store::balance(signer::address_of(market_creator), metadata(ASSET_SYMBOL_NO)), 0);

        let dust_balance = primary_fungible_store::balance(object_address(&market_obj_fee), aptos_coin_metadata);
                assert!(dust_balance == 0); // since resolution to least likely outcome, there is a remainder
    }

    #[test(aptos_framework = @aptos_framework, panana = @panana, user1 = @user1, user2 = @user2, market_creator = @admin)]
    public fun test_liq_change_many_buy_sell_liq_synth(aptos_framework: &signer, panana: &signer, user1: &signer, user2: &signer, market_creator: &signer) {
        let (burn_ref, mint_ref) = initialize_for_test(aptos_framework);
        market::init_test(aptos_framework, panana);

        let aptos_coin_metadata = *coin::paired_metadata<AptosCoin>().borrow();

        let apot_tokens_user = coin::coin_to_fungible_asset(coin::mint(1000 * OCTAS_PER_APT, &mint_ref));
        aptos_account::deposit_fungible_assets(signer::address_of(user2), apot_tokens_user);

        let apt_tokens_creator = coin::coin_to_fungible_asset(coin::mint(2000 * OCTAS_PER_APT, &mint_ref));
        aptos_account::deposit_fungible_assets(signer::address_of(market_creator), apt_tokens_creator);

        let user_tokens = coin::coin_to_fungible_asset(coin::mint(5000 * OCTAS_PER_APT, &mint_ref));
        aptos_account::deposit_fungible_assets(signer::address_of(user1), user_tokens);

        market::create_market(
            market_creator,
            aptos_coin_metadata,
            string::utf8(b"Will Panana be big?"),
            string::utf8(b"Great question with an obvious answer"),
            string::utf8(b"Always resolves to yes"),
            vector[string::utf8(b"https://panana.com")],
            0,
            100 * OCTAS_PER_APT,
            1000 * OCTAS_PER_APT,
            0,
            0,
            0,
            0,
            0,
            0,
            false,
            true
        );
        let market_obj_fee = market::market_by_id(0);
        let (lp_meta, lps_meta) = market::get_lp_tokens(market_obj_fee);

        coin::destroy_burn_cap(burn_ref);
        coin::destroy_mint_cap(mint_ref);

        market::buy_shares(user1, market_obj_fee, true, 1000 * OCTAS_PER_APT,0);
        market::add_liquidity(user2, market_obj_fee, 1000 * OCTAS_PER_APT, false);

        market::add_liquidity(market_creator, market_obj_fee, 1000 * OCTAS_PER_APT, true);

        market::withdraw_liquidity(user2, market_obj_fee, 500 * OCTAS_PER_APT, false);

        // market::sell_shares(user1, market_obj_fee, true, 500 * OCTAS_PER_APT, 0);

        market::withdraw_liquidity(market_creator, market_obj_fee, 500 * OCTAS_PER_APT, true);
        // market::sell_shares(user1, market_obj_fee, false, 100 * OCTAS_PER_APT, 0);
        // market::buy_shares(user1, market_obj_fee, true, 1000 * OCTAS_PER_APT,0);
        //
        // market::withdraw_liquidity(market_creator, market_obj_fee, primary_fungible_store::balance(signer::address_of(market_creator), lp_meta) / 3, false);
        // market::add_liquidity(user2, market_obj_fee, false, 1000 * OCTAS_PER_APT);
        // TODO: sell shares don't trigger Fee payout for LP

        market::resolve_market(market_creator, market_obj_fee, metadata(ASSET_SYMBOL_NO));
        timestamp::update_global_time_for_test_secs(4 * 60 * 60 * 24 * 7);

        market::withdraw_liquidity(market_creator, market_obj_fee, primary_fungible_store::balance(signer::address_of(market_creator), lps_meta), true);

        market::sell_shares(user1, market_obj_fee, true, primary_fungible_store::balance(signer::address_of(user1), metadata(ASSET_SYMBOL_YES)), 0);
        market::sell_shares(user2, market_obj_fee, true, primary_fungible_store::balance(signer::address_of(user2), metadata(ASSET_SYMBOL_YES)), 0);
        market::sell_shares(user2, market_obj_fee, false, primary_fungible_store::balance(signer::address_of(user2), metadata(ASSET_SYMBOL_NO)), 0);
        market::sell_shares(market_creator, market_obj_fee, true, primary_fungible_store::balance(signer::address_of(market_creator), metadata(ASSET_SYMBOL_YES)), 0);
        market::sell_shares(market_creator, market_obj_fee, false, primary_fungible_store::balance(signer::address_of(market_creator), metadata(ASSET_SYMBOL_NO)), 0);

        let dust_balance = primary_fungible_store::balance(object_address(&market_obj_fee), aptos_coin_metadata);
                assert!(dust_balance == 0); // since resolution to least likely outcome, there is a remainder
    }

    #[test(aptos_framework = @aptos_framework, panana = @panana, user1 = @user1, user2 = @user2, market_creator = @admin)]
    public fun test_fees_most_likely(aptos_framework: &signer, panana: &signer, user1: &signer, user2: &signer, market_creator: &signer) {
        let (burn_ref, mint_ref) = initialize_for_test(aptos_framework);
        market::init_test(aptos_framework, panana);

        let aptos_coin_metadata = *coin::paired_metadata<AptosCoin>().borrow();

        let apot_tokens_user = coin::coin_to_fungible_asset(coin::mint(1000 * OCTAS_PER_APT, &mint_ref));
        aptos_account::deposit_fungible_assets(signer::address_of(user2), apot_tokens_user);

        let apt_tokens_creator = coin::coin_to_fungible_asset(coin::mint(4000 * OCTAS_PER_APT, &mint_ref));
        aptos_account::deposit_fungible_assets(signer::address_of(market_creator), apt_tokens_creator);

        let user_tokens = coin::coin_to_fungible_asset(coin::mint(5000 * OCTAS_PER_APT, &mint_ref));
        aptos_account::deposit_fungible_assets(signer::address_of(user1), user_tokens);

        market::create_market(
            market_creator,
            aptos_coin_metadata,
            string::utf8(b"Will Panana be big?"),
            string::utf8(b"Great question with an obvious answer"),
            string::utf8(b"Always resolves to yes"),
            vector[string::utf8(b"https://panana.com")],
            0,
            100 * OCTAS_PER_APT,
            1000 * OCTAS_PER_APT,
            100,
            200,
            300,
            400,
            500,
            600,
            false,
            false
        );
        let market_obj_fee = market::market_by_id(0);
        let (lp_meta, lps_meta) = market::get_lp_tokens(market_obj_fee);

        coin::destroy_burn_cap(burn_ref);
        coin::destroy_mint_cap(mint_ref);

        market::buy_shares(user1, market_obj_fee, true, 1000 * OCTAS_PER_APT,0);


        let (market_fee, creator_fee, lp_fee) = market::fees(market_obj_fee);
        assert!(market_fee == 10_0000_0000);
        assert!(creator_fee == 20_0000_0000);
        assert!(lp_fee == 30_0000_0000);
        market::sell_shares(user1, market_obj_fee, true, 500 * OCTAS_PER_APT, 0);
        let (market_fee, creator_fee, lp_fee) = market::fees(market_obj_fee);
        assert!(market_fee == 25_0422_0688);
        assert!(creator_fee == 38_8027_5861);
        assert!(lp_fee == 52_5633_1033);
        market::withdraw_liquidity(market_creator, market_obj_fee, primary_fungible_store::balance(signer::address_of(market_creator), lp_meta) / 2, false);
        let (x, y) = market::prices(market_obj_fee);

        market::resolve_market(market_creator, market_obj_fee, metadata(ASSET_SYMBOL_YES));
        timestamp::update_global_time_for_test_secs(4 * 60 * 60 * 24 * 7);

        // market::withdraw_liquidity(market_creator, market_obj_fee, primary_fungible_store::balance(signer::address_of(market_creator), lps_meta), true);
        market::withdraw_liquidity(market_creator, market_obj_fee, primary_fungible_store::balance(signer::address_of(market_creator), lp_meta), false);

        market::sell_shares(user1, market_obj_fee, true, primary_fungible_store::balance(signer::address_of(user1), metadata(ASSET_SYMBOL_YES)), 0);
        market::sell_shares(market_creator, market_obj_fee, false, primary_fungible_store::balance(signer::address_of(market_creator), metadata(ASSET_SYMBOL_NO)), 0);

        let dust_balance = primary_fungible_store::balance(object_address(&market_obj_fee), aptos_coin_metadata);
        assert!(dust_balance == 2);
    }

    #[test(aptos_framework = @aptos_framework, panana = @panana, user1 = @user1, market_creator = @admin)]
    public fun test_fees_least_likely_synth(aptos_framework: &signer, panana: &signer, user1: &signer, market_creator: &signer) {
        let (burn_ref, mint_ref) = initialize_for_test(aptos_framework);
        market::init_test(aptos_framework, panana);

        let aptos_coin_metadata = *coin::paired_metadata<AptosCoin>().borrow();

        let apt_tokens_creator = coin::coin_to_fungible_asset(coin::mint(4000 * OCTAS_PER_APT, &mint_ref));
        aptos_account::deposit_fungible_assets(signer::address_of(market_creator), apt_tokens_creator);

        let user_tokens = coin::coin_to_fungible_asset(coin::mint(5000 * OCTAS_PER_APT, &mint_ref));
        aptos_account::deposit_fungible_assets(signer::address_of(user1), user_tokens);

        market::create_market(
            market_creator,
            aptos_coin_metadata,
            string::utf8(b"Will Panana be big?"),
            string::utf8(b"Great question with an obvious answer"),
            string::utf8(b"Always resolves to yes"),
            vector[string::utf8(b"https://panana.com")],
            0,
            100 * OCTAS_PER_APT,
            1000 * OCTAS_PER_APT,
            100,
            200,
            300,
            400,
            500,
            600,
            false,
            true
        );
        let market_obj_fee = market::market_by_id(0);
        let (_lp_meta, lps_meta) = market::get_lp_tokens(market_obj_fee);

        coin::destroy_burn_cap(burn_ref);
        coin::destroy_mint_cap(mint_ref);

        market::buy_shares(user1, market_obj_fee, true, 1000 * OCTAS_PER_APT,0);

        let (market_fee, creator_fee, lp_fee) = market::fees(market_obj_fee);
        assert!(market_fee == 10_0000_0000);
        assert!(creator_fee == 20_0000_0000);
        assert!(lp_fee == 30_0000_0000);
        market::sell_shares(user1, market_obj_fee, true, 500 * OCTAS_PER_APT, 0);
        let (market_fee, creator_fee, lp_fee) = market::fees(market_obj_fee);
        assert!(market_fee == 25_0422_0688);
        assert!(creator_fee == 38_8027_5861);
        assert!(lp_fee == 52_5633_1033);

        market::withdraw_liquidity(market_creator, market_obj_fee, primary_fungible_store::balance(signer::address_of(market_creator), lps_meta) / 2, true);

        let (x, y) = market::prices(market_obj_fee);

        market::resolve_market(market_creator, market_obj_fee, metadata(ASSET_SYMBOL_NO));
        timestamp::update_global_time_for_test_secs(4 * 60 * 60 * 24 * 7);

        market::withdraw_liquidity(market_creator, market_obj_fee, primary_fungible_store::balance(signer::address_of(market_creator), lps_meta), true);

        market::sell_shares(user1, market_obj_fee, true, primary_fungible_store::balance(signer::address_of(user1), metadata(ASSET_SYMBOL_YES)), 0);
        market::sell_shares(market_creator, market_obj_fee, true, primary_fungible_store::balance(signer::address_of(market_creator), metadata(ASSET_SYMBOL_YES)), 0);
        market::sell_shares(market_creator, market_obj_fee, false, primary_fungible_store::balance(signer::address_of(market_creator), metadata(ASSET_SYMBOL_NO)), 0);

        let dust_balance = primary_fungible_store::balance(object_address(&market_obj_fee), aptos_coin_metadata);
        assert!(dust_balance == 3);
    }

    #[test(aptos_framework = @aptos_framework, panana = @panana, user1 = @user1, user2 = @user2, market_creator = @admin)]
    public fun test_fees_most_likely_synth(aptos_framework: &signer, panana: &signer, user1: &signer, user2: &signer, market_creator: &signer) {
        let (burn_ref, mint_ref) = initialize_for_test(aptos_framework);
        market::init_test(aptos_framework, panana);

        let aptos_coin_metadata = *coin::paired_metadata<AptosCoin>().borrow();

        let apot_tokens_user = coin::coin_to_fungible_asset(coin::mint(1000 * OCTAS_PER_APT, &mint_ref));
        aptos_account::deposit_fungible_assets(signer::address_of(user2), apot_tokens_user);

        let apt_tokens_creator = coin::coin_to_fungible_asset(coin::mint(4000 * OCTAS_PER_APT, &mint_ref));
        aptos_account::deposit_fungible_assets(signer::address_of(market_creator), apt_tokens_creator);

        let user_tokens = coin::coin_to_fungible_asset(coin::mint(5000 * OCTAS_PER_APT, &mint_ref));
        aptos_account::deposit_fungible_assets(signer::address_of(user1), user_tokens);

        market::create_market(
            market_creator,
            aptos_coin_metadata,
            string::utf8(b"Will Panana be big?"),
            string::utf8(b"Great question with an obvious answer"),
            string::utf8(b"Always resolves to yes"),
            vector[string::utf8(b"https://panana.com")],
            0,
            100 * OCTAS_PER_APT,
            1000 * OCTAS_PER_APT,
            100,
            200,
            300,
            400,
            500,
            600,
            false,
            true
        );
        let market_obj_fee = market::market_by_id(0);
        let (lp_meta, lps_meta) = market::get_lp_tokens(market_obj_fee);

        coin::destroy_burn_cap(burn_ref);
        coin::destroy_mint_cap(mint_ref);

        market::buy_shares(user1, market_obj_fee, true, 1000 * OCTAS_PER_APT,0);


        let (market_fee, creator_fee, lp_fee) = market::fees(market_obj_fee);
        assert!(market_fee == 10_0000_0000);
        assert!(creator_fee == 20_0000_0000);
        assert!(lp_fee == 30_0000_0000);
        market::sell_shares(user1, market_obj_fee, true, 500 * OCTAS_PER_APT, 0);
        let (market_fee, creator_fee, lp_fee) = market::fees(market_obj_fee);
        assert!(market_fee == 25_0422_0688);
        assert!(creator_fee == 38_8027_5861);
        assert!(lp_fee == 52_5633_1033);
        market::withdraw_liquidity(market_creator, market_obj_fee, primary_fungible_store::balance(signer::address_of(market_creator), lps_meta) / 2, true);
        let (x, y) = market::prices(market_obj_fee);

        market::resolve_market(market_creator, market_obj_fee, metadata(ASSET_SYMBOL_YES));
        timestamp::update_global_time_for_test_secs(4 * 60 * 60 * 24 * 7);

        // market::withdraw_liquidity(market_creator, market_obj_fee, primary_fungible_store::balance(signer::address_of(market_creator), lps_meta), true);
        market::withdraw_liquidity(market_creator, market_obj_fee, primary_fungible_store::balance(signer::address_of(market_creator), lps_meta), true);

        market::sell_shares(user1, market_obj_fee, true, primary_fungible_store::balance(signer::address_of(user1), metadata(ASSET_SYMBOL_YES)), 0);
        market::sell_shares(market_creator, market_obj_fee, false, primary_fungible_store::balance(signer::address_of(market_creator), metadata(ASSET_SYMBOL_NO)), 0);

        let dust_balance = primary_fungible_store::balance(object_address(&market_obj_fee), aptos_coin_metadata);
        assert!(dust_balance == 3);
    }

    #[test(aptos_framework = @aptos_framework, panana = @panana, user1 = @user1, user2 = @user2, market_creator = @admin)]
    public fun test_fees_least_likely(aptos_framework: &signer, panana: &signer, user1: &signer, user2: &signer, market_creator: &signer) {
        let (burn_ref, mint_ref) = initialize_for_test(aptos_framework);
        market::init_test(aptos_framework, panana);

        let aptos_coin_metadata = *coin::paired_metadata<AptosCoin>().borrow();

        let apot_tokens_user = coin::coin_to_fungible_asset(coin::mint(1000 * OCTAS_PER_APT, &mint_ref));
        aptos_account::deposit_fungible_assets(signer::address_of(user2), apot_tokens_user);

        let apt_tokens_creator = coin::coin_to_fungible_asset(coin::mint(4000 * OCTAS_PER_APT, &mint_ref));
        aptos_account::deposit_fungible_assets(signer::address_of(market_creator), apt_tokens_creator);

        let user_tokens = coin::coin_to_fungible_asset(coin::mint(5000 * OCTAS_PER_APT, &mint_ref));
        aptos_account::deposit_fungible_assets(signer::address_of(user1), user_tokens);

        market::create_market(
            market_creator,
            aptos_coin_metadata,
            string::utf8(b"Will Panana be big?"),
            string::utf8(b"Great question with an obvious answer"),
            string::utf8(b"Always resolves to yes"),
            vector[string::utf8(b"https://panana.com")],
            0,
            100 * OCTAS_PER_APT,
            1000 * OCTAS_PER_APT,
            100,
            200,
            300,
            400,
            500,
            600,
            false,
            false
        );
        let market_obj_fee = market::market_by_id(0);
        let (lp_meta, lps_meta) = market::get_lp_tokens(market_obj_fee);

        coin::destroy_burn_cap(burn_ref);
        coin::destroy_mint_cap(mint_ref);

        market::buy_shares(user1, market_obj_fee, true, 1000 * OCTAS_PER_APT,0);

        let (market_fee, creator_fee, lp_fee) = market::fees(market_obj_fee);
        assert!(market_fee == 10_0000_0000);
        assert!(creator_fee == 20_0000_0000);
        assert!(lp_fee == 30_0000_0000);
        market::sell_shares(user1, market_obj_fee, true, 500 * OCTAS_PER_APT, 0);
        let (market_fee, creator_fee, lp_fee) = market::fees(market_obj_fee);
        assert!(market_fee == 25_0422_0688);
        assert!(creator_fee == 38_8027_5861);
        assert!(lp_fee == 52_5633_1033);

        market::withdraw_liquidity(market_creator, market_obj_fee, primary_fungible_store::balance(signer::address_of(market_creator), lp_meta) / 2, false);

        let (x, y) = market::prices(market_obj_fee);

        market::resolve_market(market_creator, market_obj_fee, metadata(ASSET_SYMBOL_NO));
        timestamp::update_global_time_for_test_secs(4 * 60 * 60 * 24 * 7);

        // market::withdraw_liquidity(market_creator, market_obj_fee, primary_fungible_store::balance(signer::address_of(market_creator), lps_meta), true);
        market::withdraw_liquidity(market_creator, market_obj_fee, primary_fungible_store::balance(signer::address_of(market_creator), lp_meta), false);

        market::sell_shares(user1, market_obj_fee, true, primary_fungible_store::balance(signer::address_of(user1), metadata(ASSET_SYMBOL_YES)), 0);
        market::sell_shares(market_creator, market_obj_fee, true, primary_fungible_store::balance(signer::address_of(market_creator), metadata(ASSET_SYMBOL_YES)), 0);
        market::sell_shares(market_creator, market_obj_fee, false, primary_fungible_store::balance(signer::address_of(market_creator), metadata(ASSET_SYMBOL_NO)), 0);

        let dust_balance = primary_fungible_store::balance(object_address(&market_obj_fee), aptos_coin_metadata);
        assert!(dust_balance == 3);
    }

    #[test(aptos_framework = @aptos_framework, panana = @panana, user1 = @user1, user2 = @user2, market_creator = @admin)]
    public fun test_liq_change_simple_many_buy_sell_liq(aptos_framework: &signer, panana: &signer, user1: &signer, user2: &signer, market_creator: &signer) {
        let (burn_ref, mint_ref) = initialize_for_test(aptos_framework);
        market::init_test(aptos_framework, panana);

        let aptos_coin_metadata = *coin::paired_metadata<AptosCoin>().borrow();

        let apot_tokens_user = coin::coin_to_fungible_asset(coin::mint(5000 * OCTAS_PER_APT, &mint_ref));
        aptos_account::deposit_fungible_assets(signer::address_of(user2), apot_tokens_user);

        let apt_tokens_creator = coin::coin_to_fungible_asset(coin::mint(4000 * OCTAS_PER_APT, &mint_ref));
        aptos_account::deposit_fungible_assets(signer::address_of(market_creator), apt_tokens_creator);

        let user_tokens = coin::coin_to_fungible_asset(coin::mint(5000 * OCTAS_PER_APT, &mint_ref));
        aptos_account::deposit_fungible_assets(signer::address_of(user1), user_tokens);

        market::create_market(
            market_creator,
            aptos_coin_metadata,
            string::utf8(b"Will Panana be big?"),
            string::utf8(b"Great question with an obvious answer"),
            string::utf8(b"Always resolves to yes"),
            vector[string::utf8(b"https://panana.com")],
            0,
            100 * OCTAS_PER_APT,
            1000 * OCTAS_PER_APT,
            0,
            0,
            0,
            0,
            0,
            0,
            false,
            false
        );
        let market_obj_fee = market::market_by_id(0);
        let (lp_meta, lps_meta) = market::get_lp_tokens(market_obj_fee);

        coin::destroy_burn_cap(burn_ref);
        coin::destroy_mint_cap(mint_ref);


        market::buy_shares(user1, market_obj_fee, false, 1000 * OCTAS_PER_APT,0);
        // assert!(primary_fungible_store::balance(signer::address_of(user1), metadata(ASSET_SYMBOL_NO)) == 1500_0000_0000);

        market::buy_shares(user1, market_obj_fee, true, 1500 * OCTAS_PER_APT,0);
        // assert!(primary_fungible_store::balance(signer::address_of(user1), metadata(ASSET_SYMBOL_YES)) == 3000_0000_0000);

        market::add_liquidity(market_creator, market_obj_fee, 1000 * OCTAS_PER_APT, false);
        market::buy_shares(user1, market_obj_fee, false, 1000 * OCTAS_PER_APT,0);
        market::buy_shares(user1, market_obj_fee, true, 1500 * OCTAS_PER_APT,0);
        market::sell_shares(user1, market_obj_fee, true, 1000 * OCTAS_PER_APT, 0);

        market::withdraw_liquidity(market_creator, market_obj_fee, primary_fungible_store::balance(signer::address_of(market_creator), lp_meta) / 2, false);

        market::sell_shares(user1, market_obj_fee, false, 500 * OCTAS_PER_APT, 0);

        market::resolve_market(market_creator, market_obj_fee, metadata(ASSET_SYMBOL_NO));
        timestamp::update_global_time_for_test_secs(4 * 60 * 60 * 24 * 7);

        market::withdraw_liquidity(market_creator, market_obj_fee, primary_fungible_store::balance(signer::address_of(market_creator), lp_meta), false);

        market::sell_shares(user1, market_obj_fee, true, primary_fungible_store::balance(signer::address_of(user1), metadata(ASSET_SYMBOL_YES)), 0);
        market::sell_shares(user1, market_obj_fee, false, primary_fungible_store::balance(signer::address_of(user1), metadata(ASSET_SYMBOL_NO)), 0);
        market::sell_shares(market_creator, market_obj_fee, false, primary_fungible_store::balance(signer::address_of(market_creator), metadata(ASSET_SYMBOL_NO)), 0);

        let dust_balance = primary_fungible_store::balance(object_address(&market_obj_fee), aptos_coin_metadata);
        assert!(dust_balance == 6);
    }

    #[test(aptos_framework = @aptos_framework, panana = @panana, user1 = @user1, user2 = @user2, market_creator = @admin)]
    public fun test_liq_change_simple_many_buy_sell_liq_synth(aptos_framework: &signer, panana: &signer, user1: &signer, user2: &signer, market_creator: &signer) {
        let (burn_ref, mint_ref) = initialize_for_test(aptos_framework);
        market::init_test(aptos_framework, panana);

        let aptos_coin_metadata = *coin::paired_metadata<AptosCoin>().borrow();

        let apot_tokens_user = coin::coin_to_fungible_asset(coin::mint(5000 * OCTAS_PER_APT, &mint_ref));
        aptos_account::deposit_fungible_assets(signer::address_of(user2), apot_tokens_user);

        let apt_tokens_creator = coin::coin_to_fungible_asset(coin::mint(4000 * OCTAS_PER_APT, &mint_ref));
        aptos_account::deposit_fungible_assets(signer::address_of(market_creator), apt_tokens_creator);

        let user_tokens = coin::coin_to_fungible_asset(coin::mint(5000 * OCTAS_PER_APT, &mint_ref));
        aptos_account::deposit_fungible_assets(signer::address_of(user1), user_tokens);

        market::create_market(
            market_creator,
            aptos_coin_metadata,
            string::utf8(b"Will Panana be big?"),
            string::utf8(b"Great question with an obvious answer"),
            string::utf8(b"Always resolves to yes"),
            vector[string::utf8(b"https://panana.com")],
            0,
            100 * OCTAS_PER_APT,
            1000 * OCTAS_PER_APT,
            0,
            0,
            0,
            0,
            0,
            0,
            false,
            true
        );
        let market_obj_fee = market::market_by_id(0);
        let (lp_meta, lps_meta) = market::get_lp_tokens(market_obj_fee);

        coin::destroy_burn_cap(burn_ref);
        coin::destroy_mint_cap(mint_ref);


        market::buy_shares(user1, market_obj_fee, false, 1000 * OCTAS_PER_APT,0);
        assert!(primary_fungible_store::balance(signer::address_of(user1), metadata(ASSET_SYMBOL_NO)) == 1500_0000_0000);

        market::buy_shares(user1, market_obj_fee, true, 1500 * OCTAS_PER_APT,0);
        assert!(primary_fungible_store::balance(signer::address_of(user1), metadata(ASSET_SYMBOL_YES)) == 3000_0000_0000);

        market::add_liquidity(market_creator, market_obj_fee, 1000 * OCTAS_PER_APT, true);
        market::buy_shares(user1, market_obj_fee, false, 1000 * OCTAS_PER_APT,0);
        market::buy_shares(user1, market_obj_fee, true, 1500 * OCTAS_PER_APT,0);
        market::sell_shares(user1, market_obj_fee, true, 1000 * OCTAS_PER_APT, 0);

        market::withdraw_liquidity(market_creator, market_obj_fee, primary_fungible_store::balance(signer::address_of(market_creator), lps_meta) / 2, true);

        market::sell_shares(user1, market_obj_fee, false, 500 * OCTAS_PER_APT, 0);

        market::resolve_market(market_creator, market_obj_fee, metadata(ASSET_SYMBOL_NO));
        timestamp::update_global_time_for_test_secs(4 * 60 * 60 * 24 * 7);

        market::withdraw_liquidity(market_creator, market_obj_fee, primary_fungible_store::balance(signer::address_of(market_creator), lps_meta), true);

        market::sell_shares(user1, market_obj_fee, true, primary_fungible_store::balance(signer::address_of(user1), metadata(ASSET_SYMBOL_YES)), 0);
        market::sell_shares(user1, market_obj_fee, false, primary_fungible_store::balance(signer::address_of(user1), metadata(ASSET_SYMBOL_NO)), 0);
        market::sell_shares(market_creator, market_obj_fee, false, primary_fungible_store::balance(signer::address_of(market_creator), metadata(ASSET_SYMBOL_NO)), 0);

        let dust_balance = primary_fungible_store::balance(object_address(&market_obj_fee), aptos_coin_metadata);
        assert!(dust_balance == 6);
    }

    #[test(aptos_framework = @aptos_framework, panana = @panana, user1 = @user1, user2 = @user2, market_creator = @admin)]
    public fun test_many_buy_sell_after_resolution_before_final(aptos_framework: &signer, panana: &signer, user1: &signer, user2: &signer, market_creator: &signer) {
        let (burn_ref, mint_ref) = initialize_for_test(aptos_framework);
        market::init_test(aptos_framework, panana);

        let aptos_coin_metadata = *coin::paired_metadata<AptosCoin>().borrow();

        let apot_tokens_user = coin::coin_to_fungible_asset(coin::mint(5000 * OCTAS_PER_APT, &mint_ref));
        aptos_account::deposit_fungible_assets(signer::address_of(user2), apot_tokens_user);

        let apt_tokens_creator = coin::coin_to_fungible_asset(coin::mint(4000 * OCTAS_PER_APT, &mint_ref));
        aptos_account::deposit_fungible_assets(signer::address_of(market_creator), apt_tokens_creator);

        let user_tokens = coin::coin_to_fungible_asset(coin::mint(5000 * OCTAS_PER_APT, &mint_ref));
        aptos_account::deposit_fungible_assets(signer::address_of(user1), user_tokens);

        market::create_market(
            market_creator,
            aptos_coin_metadata,
            string::utf8(b"Will Panana be big?"),
            string::utf8(b"Great question with an obvious answer"),
            string::utf8(b"Always resolves to yes"),
            vector[string::utf8(b"https://panana.com")],
            0,
            100 * OCTAS_PER_APT,
            1000 * OCTAS_PER_APT,
            0,
            0,
            0,
            0,
            0,
            0,
            false,
            false
        );
        let market_obj_fee = market::market_by_id(0);

        coin::destroy_burn_cap(burn_ref);
        coin::destroy_mint_cap(mint_ref);

        // resolve market without having the market finally resolved (challenge time not passed)
        market::resolve_market(market_creator, market_obj_fee, metadata(ASSET_SYMBOL_YES));

        market::buy_shares(user1, market_obj_fee, false, 1000 * OCTAS_PER_APT,0);
        assert!(primary_fungible_store::balance(signer::address_of(user1), metadata(ASSET_SYMBOL_NO)) == 1500_0000_0000);

        market::buy_shares(user1, market_obj_fee, true, 1000 * OCTAS_PER_APT,0);
        assert!(primary_fungible_store::balance(signer::address_of(user1), metadata(ASSET_SYMBOL_YES)) == 2333_3333_3333);

        market::buy_shares(user1, market_obj_fee, false, 666 * OCTAS_PER_APT,0);
        assert!(primary_fungible_store::balance(signer::address_of(user1), metadata(ASSET_SYMBOL_NO)) == 2915_6248_1240);

        let balance_before = primary_fungible_store::balance(signer::address_of(user1), aptos_coin_metadata);
        market::sell_shares(user1, market_obj_fee, false,800_0000_0000, 0);
        let balance_after = primary_fungible_store::balance(signer::address_of(user1), aptos_coin_metadata);
        assert!(primary_fungible_store::balance(signer::address_of(user1), metadata(ASSET_SYMBOL_NO)) == 2115_6248_1240);
        assert!(balance_after - balance_before == 435_6137_4949);


        let balance_before = primary_fungible_store::balance(signer::address_of(user1), aptos_coin_metadata);
        market::sell_shares(user1, market_obj_fee, true, 500_0000_0000, 0);
        let balance_after = primary_fungible_store::balance(signer::address_of(user1), aptos_coin_metadata);
        assert!(primary_fungible_store::balance(signer::address_of(user1), metadata(ASSET_SYMBOL_YES)) == 1833_3333_3333);
        assert!(balance_after - balance_before == 245_9952_4098);

        market::buy_shares(user2, market_obj_fee, true, 666 * OCTAS_PER_APT,0);
        assert!(primary_fungible_store::balance(signer::address_of(user2), metadata(ASSET_SYMBOL_YES)) == 1165_4926_3528);

        market::buy_shares(user2, market_obj_fee, false, 666 * OCTAS_PER_APT,0);
        assert!(primary_fungible_store::balance(signer::address_of(user2), metadata(ASSET_SYMBOL_NO)) == 1441_7903_8266);

        let balance_before = primary_fungible_store::balance(signer::address_of(user2), aptos_coin_metadata);
        market::sell_shares(user2, market_obj_fee, true, 100 * OCTAS_PER_APT, 0);
        let balance_after = primary_fungible_store::balance(signer::address_of(user2), aptos_coin_metadata);
        assert!(primary_fungible_store::balance(signer::address_of(user2), metadata(ASSET_SYMBOL_YES)) == 1065_4926_3528);
        assert!(balance_after - balance_before == 35_4480_5789);


        let balance_before = primary_fungible_store::balance(signer::address_of(user1), aptos_coin_metadata);
        market::sell_shares(user1, market_obj_fee, false, 500 * OCTAS_PER_APT, 0);
        let balance_after = primary_fungible_store::balance(signer::address_of(user1), aptos_coin_metadata);
        assert!(primary_fungible_store::balance(signer::address_of(user1), metadata(ASSET_SYMBOL_NO)) == 1615_6248_1240);
        assert!(balance_after - balance_before == 299_6834_7825);

        market::buy_shares(user2, market_obj_fee, false, 666 * OCTAS_PER_APT,0);

        assert!(primary_fungible_store::balance(signer::address_of(user2), metadata(ASSET_SYMBOL_NO)) == 2459_6941_2259);
        assert!(primary_fungible_store::balance(signer::address_of(user1), aptos_coin_metadata) == 3315_2924_6872);
        assert!(primary_fungible_store::balance(signer::address_of(user2), aptos_coin_metadata) == 3037_4480_5789);


        let balance_before = primary_fungible_store::balance(signer::address_of(market_creator), aptos_coin_metadata);

        market::withdraw_liquidity(market_creator, market_obj_fee, 100 * OCTAS_PER_APT, false);
        let balance_after = primary_fungible_store::balance(signer::address_of(market_creator), aptos_coin_metadata);
        assert!(balance_after - balance_before == 57_1940_5383);
        assert!(primary_fungible_store::balance(signer::address_of(market_creator), metadata(ASSET_SYMBOL_YES)) == 117_6492_9664);
        assert!(primary_fungible_store::balance(signer::address_of(market_creator), metadata(ASSET_SYMBOL_NO)) == 0);

        timestamp::update_global_time_for_test_secs(4 * 60 * 60 * 24 * 7);

        let balance_before = primary_fungible_store::balance(signer::address_of(market_creator), aptos_coin_metadata);
        market::withdraw_liquidity(market_creator, market_obj_fee, 900 * OCTAS_PER_APT, false);
        let balance_after = primary_fungible_store::balance(signer::address_of(market_creator), aptos_coin_metadata);
        assert!(balance_after - balance_before == 1573_5901_5422);
        assert!(primary_fungible_store::balance(signer::address_of(market_creator), metadata(ASSET_SYMBOL_YES)) == 117_6492_9664);
        assert!(primary_fungible_store::balance(signer::address_of(market_creator), metadata(ASSET_SYMBOL_NO)) == 3);


        market::sell_shares(user1, market_obj_fee, true, primary_fungible_store::balance(signer::address_of(user1), metadata(ASSET_SYMBOL_YES)), 0);
        market::sell_shares(user1, market_obj_fee, false, primary_fungible_store::balance(signer::address_of(user1), metadata(ASSET_SYMBOL_NO)), 0);
        market::sell_shares(user2, market_obj_fee, true, primary_fungible_store::balance(signer::address_of(user2), metadata(ASSET_SYMBOL_YES)), 0);
        market::sell_shares(user2, market_obj_fee, false, primary_fungible_store::balance(signer::address_of(user2), metadata(ASSET_SYMBOL_NO)), 0);
        market::sell_shares(market_creator, market_obj_fee, true, primary_fungible_store::balance(signer::address_of(market_creator), metadata(ASSET_SYMBOL_YES)), 0);
        market::sell_shares(market_creator, market_obj_fee, false, primary_fungible_store::balance(signer::address_of(market_creator), metadata(ASSET_SYMBOL_NO)), 0);

        let dust_balance = primary_fungible_store::balance(object_address(&market_obj_fee), aptos_coin_metadata);
        assert!(dust_balance == 9);
    }

    #[test(aptos_framework = @aptos_framework, panana = @panana, user1 = @user1, user2 = @user2, market_creator = @admin)]
    public fun test_many_buy_sell(aptos_framework: &signer, panana: &signer, user1: &signer, user2: &signer, market_creator: &signer) {
        let (burn_ref, mint_ref) = initialize_for_test(aptos_framework);
        market::init_test(aptos_framework, panana);

        let aptos_coin_metadata = *coin::paired_metadata<AptosCoin>().borrow();

        let apot_tokens_user = coin::coin_to_fungible_asset(coin::mint(5000 * OCTAS_PER_APT, &mint_ref));
        aptos_account::deposit_fungible_assets(signer::address_of(user2), apot_tokens_user);

        let apt_tokens_creator = coin::coin_to_fungible_asset(coin::mint(4000 * OCTAS_PER_APT, &mint_ref));
        aptos_account::deposit_fungible_assets(signer::address_of(market_creator), apt_tokens_creator);

        let user_tokens = coin::coin_to_fungible_asset(coin::mint(5000 * OCTAS_PER_APT, &mint_ref));
        aptos_account::deposit_fungible_assets(signer::address_of(user1), user_tokens);

        market::create_market(
            market_creator,
            aptos_coin_metadata,
            string::utf8(b"Will Panana be big?"),
            string::utf8(b"Great question with an obvious answer"),
            string::utf8(b"Always resolves to yes"),
            vector[string::utf8(b"https://panana.com")],
            0,
            100 * OCTAS_PER_APT,
            1000 * OCTAS_PER_APT,
            0,
            0,
            0,
            0,
            0,
            0,
            false,
            false
        );
        let market_obj_fee = market::market_by_id(0);

        coin::destroy_burn_cap(burn_ref);
        coin::destroy_mint_cap(mint_ref);


        market::buy_shares(user1, market_obj_fee, false, 1000 * OCTAS_PER_APT,0);
        assert!(primary_fungible_store::balance(signer::address_of(user1), metadata(ASSET_SYMBOL_NO)) == 1500_0000_0000);

        market::buy_shares(user1, market_obj_fee, true, 1000 * OCTAS_PER_APT,0);
        assert!(primary_fungible_store::balance(signer::address_of(user1), metadata(ASSET_SYMBOL_YES)) == 2333_3333_3333);

        market::buy_shares(user1, market_obj_fee, false, 666 * OCTAS_PER_APT,0);
        assert!(primary_fungible_store::balance(signer::address_of(user1), metadata(ASSET_SYMBOL_NO)) == 2915_6248_1240);

        let balance_before = primary_fungible_store::balance(signer::address_of(user1), aptos_coin_metadata);
        market::sell_shares(user1, market_obj_fee, false,800_0000_0000, 0);
        let balance_after = primary_fungible_store::balance(signer::address_of(user1), aptos_coin_metadata);
        assert!(primary_fungible_store::balance(signer::address_of(user1), metadata(ASSET_SYMBOL_NO)) == 2115_6248_1240);
        assert!(balance_after - balance_before == 435_6137_4949);


        let balance_before = primary_fungible_store::balance(signer::address_of(user1), aptos_coin_metadata);
        market::sell_shares(user1, market_obj_fee, true, 500_0000_0000, 0);
        let balance_after = primary_fungible_store::balance(signer::address_of(user1), aptos_coin_metadata);
        assert!(primary_fungible_store::balance(signer::address_of(user1), metadata(ASSET_SYMBOL_YES)) == 1833_3333_3333);
        assert!(balance_after - balance_before == 245_9952_4098);

        market::buy_shares(user2, market_obj_fee, true, 666 * OCTAS_PER_APT,0);
        assert!(primary_fungible_store::balance(signer::address_of(user2), metadata(ASSET_SYMBOL_YES)) == 1165_4926_3528);

        market::buy_shares(user2, market_obj_fee, false, 666 * OCTAS_PER_APT,0);
        assert!(primary_fungible_store::balance(signer::address_of(user2), metadata(ASSET_SYMBOL_NO)) == 1441_7903_8266);

        let balance_before = primary_fungible_store::balance(signer::address_of(user2), aptos_coin_metadata);
        market::sell_shares(user2, market_obj_fee, true, 100 * OCTAS_PER_APT, 0);
        let balance_after = primary_fungible_store::balance(signer::address_of(user2), aptos_coin_metadata);
        assert!(primary_fungible_store::balance(signer::address_of(user2), metadata(ASSET_SYMBOL_YES)) == 1065_4926_3528);
        assert!(balance_after - balance_before == 35_4480_5789);


        let balance_before = primary_fungible_store::balance(signer::address_of(user1), aptos_coin_metadata);
        market::sell_shares(user1, market_obj_fee, false, 500 * OCTAS_PER_APT, 0);
        let balance_after = primary_fungible_store::balance(signer::address_of(user1), aptos_coin_metadata);
        assert!(primary_fungible_store::balance(signer::address_of(user1), metadata(ASSET_SYMBOL_NO)) == 1615_6248_1240);
        assert!(balance_after - balance_before == 299_6834_7825);

        market::buy_shares(user2, market_obj_fee, false, 666 * OCTAS_PER_APT,0);

        assert!(primary_fungible_store::balance(signer::address_of(user2), metadata(ASSET_SYMBOL_NO)) == 2459_6941_2259);
        assert!(primary_fungible_store::balance(signer::address_of(user1), aptos_coin_metadata) == 3315_2924_6872);
        assert!(primary_fungible_store::balance(signer::address_of(user2), aptos_coin_metadata) == 3037_4480_5789);


        let balance_before = primary_fungible_store::balance(signer::address_of(market_creator), aptos_coin_metadata);

        market::withdraw_liquidity(market_creator, market_obj_fee, 100 * OCTAS_PER_APT, false);
        let balance_after = primary_fungible_store::balance(signer::address_of(market_creator), aptos_coin_metadata);
        assert!(balance_after - balance_before == 57_1940_5383);
        assert!(primary_fungible_store::balance(signer::address_of(market_creator), metadata(ASSET_SYMBOL_YES)) == 117_6492_9664);
        assert!(primary_fungible_store::balance(signer::address_of(market_creator), metadata(ASSET_SYMBOL_NO)) == 0);

        market::resolve_market(market_creator, market_obj_fee, metadata(ASSET_SYMBOL_YES));
        timestamp::update_global_time_for_test_secs(4 * 60 * 60 * 24 * 7);

        let balance_before = primary_fungible_store::balance(signer::address_of(market_creator), aptos_coin_metadata);
        market::withdraw_liquidity(market_creator, market_obj_fee, 900 * OCTAS_PER_APT, false);
        let balance_after = primary_fungible_store::balance(signer::address_of(market_creator), aptos_coin_metadata);
        assert!(balance_after - balance_before == 1573_5901_5422);
        assert!(primary_fungible_store::balance(signer::address_of(market_creator), metadata(ASSET_SYMBOL_YES)) == 117_6492_9664);
        assert!(primary_fungible_store::balance(signer::address_of(market_creator), metadata(ASSET_SYMBOL_NO)) == 3);


        market::sell_shares(user1, market_obj_fee, true, primary_fungible_store::balance(signer::address_of(user1), metadata(ASSET_SYMBOL_YES)), 0);
        market::sell_shares(user1, market_obj_fee, false, primary_fungible_store::balance(signer::address_of(user1), metadata(ASSET_SYMBOL_NO)), 0);
        market::sell_shares(user2, market_obj_fee, true, primary_fungible_store::balance(signer::address_of(user2), metadata(ASSET_SYMBOL_YES)), 0);
        market::sell_shares(user2, market_obj_fee, false, primary_fungible_store::balance(signer::address_of(user2), metadata(ASSET_SYMBOL_NO)), 0);
        market::sell_shares(market_creator, market_obj_fee, true, primary_fungible_store::balance(signer::address_of(market_creator), metadata(ASSET_SYMBOL_YES)), 0);
        market::sell_shares(market_creator, market_obj_fee, false, primary_fungible_store::balance(signer::address_of(market_creator), metadata(ASSET_SYMBOL_NO)), 0);

        let dust_balance = primary_fungible_store::balance(object_address(&market_obj_fee), aptos_coin_metadata);
        assert!(dust_balance == 9);
    }

    #[test(aptos_framework = @aptos_framework, panana = @panana, user1 = @user1, user2 = @user2, market_creator = @admin)]
    public fun test_many_buy_sell_synth(aptos_framework: &signer, panana: &signer, user1: &signer, user2: &signer, market_creator: &signer) {
        let (burn_ref, mint_ref) = initialize_for_test(aptos_framework);
        market::init_test(aptos_framework, panana);

        let aptos_coin_metadata = *coin::paired_metadata<AptosCoin>().borrow();

        let apot_tokens_user = coin::coin_to_fungible_asset(coin::mint(5000 * OCTAS_PER_APT, &mint_ref));
        aptos_account::deposit_fungible_assets(signer::address_of(user2), apot_tokens_user);

        let apt_tokens_creator = coin::coin_to_fungible_asset(coin::mint(4000 * OCTAS_PER_APT, &mint_ref));
        aptos_account::deposit_fungible_assets(signer::address_of(market_creator), apt_tokens_creator);

        let user_tokens = coin::coin_to_fungible_asset(coin::mint(5000 * OCTAS_PER_APT, &mint_ref));
        aptos_account::deposit_fungible_assets(signer::address_of(user1), user_tokens);

        market::create_market(
            market_creator,
            aptos_coin_metadata,
            string::utf8(b"Will Panana be big?"),
            string::utf8(b"Great question with an obvious answer"),
            string::utf8(b"Always resolves to yes"),
            vector[string::utf8(b"https://panana.com")],
            0,
            100 * OCTAS_PER_APT,
            1000 * OCTAS_PER_APT,
            0,
            0,
            0,
            0,
            0,
            0,
            false,
            true
        );
        let market_obj_fee = market::market_by_id(0);

        coin::destroy_burn_cap(burn_ref);
        coin::destroy_mint_cap(mint_ref);



        market::buy_shares(user1, market_obj_fee, false, 1000 * OCTAS_PER_APT,0);
        market::buy_shares(user1, market_obj_fee, true, 1000 * OCTAS_PER_APT,0);
        market::buy_shares(user1, market_obj_fee, false, 666 * OCTAS_PER_APT,0);
        market::sell_shares(user1, market_obj_fee, false,800_0000_0000, 0);
        market::sell_shares(user1, market_obj_fee, true, 500_0000_0000, 0);
        market::buy_shares(user2, market_obj_fee, true, 666 * OCTAS_PER_APT,0);
        market::buy_shares(user2, market_obj_fee, false, 666 * OCTAS_PER_APT,0);
        market::sell_shares(user2, market_obj_fee, true, 100 * OCTAS_PER_APT, 0);
        market::sell_shares(user1, market_obj_fee, false, 500 * OCTAS_PER_APT, 0);
        market::buy_shares(user2, market_obj_fee, false, 666 * OCTAS_PER_APT,0);



        market::withdraw_liquidity(market_creator, market_obj_fee, 100 * OCTAS_PER_APT, true);


        market::resolve_market(market_creator, market_obj_fee, metadata(ASSET_SYMBOL_YES));
        timestamp::update_global_time_for_test_secs(4 * 60 * 60 * 24 * 7);

        market::withdraw_liquidity(market_creator, market_obj_fee, 900 * OCTAS_PER_APT, true);


        market::sell_shares(user1, market_obj_fee, true, primary_fungible_store::balance(signer::address_of(user1), metadata(ASSET_SYMBOL_YES)), 0);
        market::sell_shares(user1, market_obj_fee, false, primary_fungible_store::balance(signer::address_of(user1), metadata(ASSET_SYMBOL_NO)), 0);
        market::sell_shares(user2, market_obj_fee, true, primary_fungible_store::balance(signer::address_of(user2), metadata(ASSET_SYMBOL_YES)), 0);
        market::sell_shares(user2, market_obj_fee, false, primary_fungible_store::balance(signer::address_of(user2), metadata(ASSET_SYMBOL_NO)), 0);
        market::sell_shares(market_creator, market_obj_fee, true, primary_fungible_store::balance(signer::address_of(market_creator), metadata(ASSET_SYMBOL_YES)), 0);
        market::sell_shares(market_creator, market_obj_fee, false, primary_fungible_store::balance(signer::address_of(market_creator), metadata(ASSET_SYMBOL_NO)), 0);

        let dust_balance = primary_fungible_store::balance(object_address(&market_obj_fee), aptos_coin_metadata);
        assert!(dust_balance == 9);
    }

    #[test(aptos_framework = @aptos_framework, panana = @panana, user1 = @user1, user2 = @user2, market_creator = @admin)]
    public fun test_liquidity_many_buy_sell_withdrawal(aptos_framework: &signer, panana: &signer, user1: &signer, user2: &signer, market_creator: &signer) {
        let (burn_ref, mint_ref) = initialize_for_test(aptos_framework);
        market::init_test(aptos_framework, panana);

        let aptos_coin_metadata = *coin::paired_metadata<AptosCoin>().borrow();

        let apot_tokens_user = coin::coin_to_fungible_asset(coin::mint(5000 * OCTAS_PER_APT, &mint_ref));
        aptos_account::deposit_fungible_assets(signer::address_of(user2), apot_tokens_user);

        let apt_tokens_creator = coin::coin_to_fungible_asset(coin::mint(4000 * OCTAS_PER_APT, &mint_ref));
        aptos_account::deposit_fungible_assets(signer::address_of(market_creator), apt_tokens_creator);

        let user_tokens = coin::coin_to_fungible_asset(coin::mint(5000 * OCTAS_PER_APT, &mint_ref));
        aptos_account::deposit_fungible_assets(signer::address_of(user1), user_tokens);

        market::create_market(
            market_creator,
            aptos_coin_metadata,
            string::utf8(b"Will Panana be big?"),
            string::utf8(b"Great question with an obvious answer"),
            string::utf8(b"Always resolves to yes"),
            vector[string::utf8(b"https://panana.com")],
            0,
            1000 * OCTAS_PER_APT,
            1000 * OCTAS_PER_APT,
            0,
            0,
            0,
            0,
            0,
            0,
            false,
            true
        );
        let market_obj_fee = market::market_by_id(0);
        let (lp_meta, lps_meta) = market::get_lp_tokens(market_obj_fee);
        assert!(primary_fungible_store::balance (signer::address_of(market_creator),lps_meta) == 1000 * OCTAS_PER_APT);

        coin::destroy_burn_cap(burn_ref);
        coin::destroy_mint_cap(mint_ref);


        market::buy_shares(user1, market_obj_fee, false, 1000 * OCTAS_PER_APT,0);
        market::add_liquidity(market_creator, market_obj_fee, 1000 * OCTAS_PER_APT, false);
        market::add_liquidity(user2, market_obj_fee, 2000 * OCTAS_PER_APT, false);

        market::add_liquidity(market_creator, market_obj_fee, 1000 * OCTAS_PER_APT, false);
        market::buy_shares(user1, market_obj_fee, true, 1000 * OCTAS_PER_APT,0);
        market::buy_shares(user1, market_obj_fee, false, 666 * OCTAS_PER_APT,0);
        market::sell_shares(user1, market_obj_fee, false,800 * OCTAS_PER_APT, 0);
        market::withdraw_liquidity(user2, market_obj_fee, 1000 * OCTAS_PER_APT, false);
        market::sell_shares(user1, market_obj_fee, true, 500 * OCTAS_PER_APT, 0);

        market::withdraw_liquidity(market_creator, market_obj_fee, 500 * OCTAS_PER_APT, false);
        market::sell_shares(user1, market_obj_fee, false, 100 * OCTAS_PER_APT, 0);
        market::buy_shares(user1, market_obj_fee, true, 1000 * OCTAS_PER_APT,0);

        market::withdraw_liquidity(market_creator, market_obj_fee, primary_fungible_store::balance(signer::address_of(market_creator), lp_meta) / 3, false);
        market::add_liquidity(user2, market_obj_fee, 1000 * OCTAS_PER_APT, false);

        market::resolve_market(market_creator, market_obj_fee, metadata(ASSET_SYMBOL_NO));
        timestamp::update_global_time_for_test_secs(4 * 60 * 60 * 24 * 7);

        market::withdraw_liquidity(market_creator, market_obj_fee, primary_fungible_store::balance(signer::address_of(market_creator), lps_meta), true);
        market::withdraw_liquidity(market_creator, market_obj_fee, primary_fungible_store::balance(signer::address_of(market_creator), lp_meta), false);
        market::withdraw_liquidity(user2, market_obj_fee, primary_fungible_store::balance(signer::address_of(user2), lp_meta), false);

        market::sell_shares(user1, market_obj_fee, true, primary_fungible_store::balance(signer::address_of(user1), metadata(ASSET_SYMBOL_YES)), 0);
        market::sell_shares(user1, market_obj_fee, false, primary_fungible_store::balance(signer::address_of(user1), metadata(ASSET_SYMBOL_NO)), 0);
        market::sell_shares(user2, market_obj_fee, true, primary_fungible_store::balance(signer::address_of(user2), metadata(ASSET_SYMBOL_YES)), 0);
        market::sell_shares(user2, market_obj_fee, false, primary_fungible_store::balance(signer::address_of(user2), metadata(ASSET_SYMBOL_NO)), 0);
        market::sell_shares(market_creator, market_obj_fee, true, primary_fungible_store::balance(signer::address_of(market_creator), metadata(ASSET_SYMBOL_YES)), 0);
        market::sell_shares(market_creator, market_obj_fee, false, primary_fungible_store::balance(signer::address_of(market_creator), metadata(ASSET_SYMBOL_NO)), 0);


        let dust_balance = primary_fungible_store::balance(object_address(&market_obj_fee), aptos_coin_metadata);
        assert!(dust_balance == 12);
    }

    #[test(aptos_framework = @aptos_framework, panana = @panana, user1 = @user1, user2 = @user2, market_creator = @admin)]
    public fun test_no_leftover_after_least_likely_resolution(aptos_framework: &signer, panana: &signer, user1: &signer, user2: &signer, market_creator: &signer) {
        let (burn_ref, mint_ref) = initialize_for_test(aptos_framework);
        market::init_test(aptos_framework, panana);

        let aptos_coin_metadata = *coin::paired_metadata<AptosCoin>().borrow();

        let apot_tokens_user = coin::coin_to_fungible_asset(coin::mint(5000 * OCTAS_PER_APT, &mint_ref));
        aptos_account::deposit_fungible_assets(signer::address_of(user2), apot_tokens_user);

        let apt_tokens_creator = coin::coin_to_fungible_asset(coin::mint(1000 * OCTAS_PER_APT, &mint_ref));
        aptos_account::deposit_fungible_assets(signer::address_of(market_creator), apt_tokens_creator);

        let user_tokens = coin::coin_to_fungible_asset(coin::mint(5000 * OCTAS_PER_APT, &mint_ref));
        aptos_account::deposit_fungible_assets(signer::address_of(user1), user_tokens);

        market::create_market(
            market_creator,
            aptos_coin_metadata,
            string::utf8(b"Will Panana be big?"),
            string::utf8(b"Great question with an obvious answer"),
            string::utf8(b"Always resolves to yes"),
            vector[string::utf8(b"https://panana.com")],
            0,
            1000 * OCTAS_PER_APT,
            1000 * OCTAS_PER_APT,
            0,
            0,
            0,
            0,
            0,
            0,
            false,
            false
        );
        let market_obj_fee = market::market_by_id(0);
        let (lp_meta, lps_meta) = market::get_lp_tokens(market_obj_fee);

        coin::destroy_burn_cap(burn_ref);
        coin::destroy_mint_cap(mint_ref);


        market::buy_shares(user1, market_obj_fee, false, 1000 * OCTAS_PER_APT,0);

        market::resolve_market(market_creator, market_obj_fee, metadata(ASSET_SYMBOL_YES));
        timestamp::update_global_time_for_test_secs(4 * 60 * 60 * 24 * 7);

        market::withdraw_liquidity(market_creator, market_obj_fee, primary_fungible_store::balance(signer::address_of(market_creator), lp_meta), false);

        market::sell_shares(user1, market_obj_fee, false, primary_fungible_store::balance(signer::address_of(user1), metadata(ASSET_SYMBOL_NO)), 0);

        assert!(primary_fungible_store::balance(signer::address_of(market_creator),aptos_coin_metadata) == 2000 * OCTAS_PER_APT);

        let dust_balance = primary_fungible_store::balance(object_address(&market_obj_fee), aptos_coin_metadata);
        assert!(dust_balance == 0);
    }

    #[test(aptos_framework = @aptos_framework, panana = @panana, user1 = @user1, market_creator = @admin)]
    public fun test_buy_in_market_and_creator_fee(aptos_framework: &signer, panana: &signer, user1: &signer, market_creator: &signer) {
        let (burn_ref, mint_ref) = initialize_for_test(aptos_framework);
        market::init_test(aptos_framework, panana);

        let aptos_coin_metadata = *coin::paired_metadata<AptosCoin>().borrow();

        market::create_market(
            market_creator,
            aptos_coin_metadata,
            string::utf8(b"Will Panana be big?"),
            string::utf8(b"Great question with an obvious answer"),
            string::utf8(b"Always resolves to yes"),
            vector[string::utf8(b"https://panana.com")],
            0,
            100 * OCTAS_PER_APT,
            100 * OCTAS_PER_APT,
            1000,
            2000,
            0,
            0,
            0,
            0,
            false,
            true
        );
        let market_obj = market::market_by_id(0);

        let user_tokens = coin::coin_to_fungible_asset(coin::mint(50 * OCTAS_PER_APT, &mint_ref));
        aptos_account::deposit_fungible_assets(signer::address_of(user1), user_tokens);
        coin::destroy_burn_cap(burn_ref);
        coin::destroy_mint_cap(mint_ref);

        market::buy_shares(user1, market_obj, true, 5 * OCTAS_PER_APT, 0);

        let (market_fee, creator_fee, _) = market::fees(market_obj);
        assert!(market_fee == 5000_0000, 0);
        assert!(creator_fee == 1_0000_0000, 0);

        market::collect_fees(market_creator, market_obj);
        let fee_aptos_balance = primary_fungible_store::balance(signer::address_of(market_creator), aptos_coin_metadata);
        // Market fee recipient and creator are the same.
        assert!(fee_aptos_balance == 1_5000_0000, 0);
    }

    #[test(aptos_framework = @aptos_framework, panana = @panana, user1 = @user1, market_creator = @admin, user2 = @user2)]
    public fun test_buy_in_user(aptos_framework: &signer, panana: &signer, user1: &signer, user2: &signer, market_creator: &signer) {
        let (burn_ref, mint_ref) = initialize_for_test(aptos_framework);
        market::init_test(aptos_framework, panana);

        let aptos_coin_metadata = *coin::paired_metadata<AptosCoin>().borrow();

        market::create_market(
            market_creator,
            aptos_coin_metadata,
            string::utf8(b"Will Panana be big?"),
            string::utf8(b"Great question with an obvious answer"),
            string::utf8(b"Always resolves to yes"),
            vector[string::utf8(b"https://panana.com")],
            0,
            100 * OCTAS_PER_APT,
            100 * OCTAS_PER_APT,
            0,
            0,
            0,
            0,
            0,
            0,
            false,
            true
        );
        let market_obj = market::market_by_id(0);

        let user_tokens = coin::coin_to_fungible_asset(coin::mint(50 * OCTAS_PER_APT, &mint_ref));
        aptos_account::deposit_fungible_assets(signer::address_of(user1), user_tokens);

        let user2_tokens = coin::coin_to_fungible_asset(coin::mint(50 * OCTAS_PER_APT, &mint_ref));
        aptos_account::deposit_fungible_assets(signer::address_of(user2), user2_tokens);
        coin::destroy_burn_cap(burn_ref);
        coin::destroy_mint_cap(mint_ref);

        let (yes_buyin, no_buyin) = market::user_buyin(market_obj, signer::address_of(user1));
        assert!(yes_buyin == 0);
        assert!(no_buyin == 0);
        market::buy_shares(user1, market_obj, true, 5 * OCTAS_PER_APT, 0);

        // avg price after buy in
        let user_shares = primary_fungible_store::balance(signer::address_of(user1), metadata(ASSET_SYMBOL_YES));
        let (yes_buyin, no_buyin) = market::user_buyin(market_obj, signer::address_of(user1));
        assert!(yes_buyin == math64::mul_div(constants::price_scaling_factor(), 5 * OCTAS_PER_APT, user_shares));
        assert!(no_buyin == 0);

        // Validate avg. price per share decreasing and calculation for yes and no work properly
        market::buy_shares(user2, market_obj, false, 50 * OCTAS_PER_APT, 0);
        market::buy_shares(user1, market_obj, true, 5 * OCTAS_PER_APT, 0);
        market::buy_shares(user1, market_obj, false, 5 * OCTAS_PER_APT, 0);
        let (yes_buyin2, no_buyin2) = market::user_buyin(market_obj, signer::address_of(user1));
        let user_yes_shares = primary_fungible_store::balance(signer::address_of(user1), metadata(ASSET_SYMBOL_YES));
        let user_no_shares = primary_fungible_store::balance(signer::address_of(user1), metadata(ASSET_SYMBOL_NO));
        assert!(yes_buyin2 == math64::mul_div(constants::price_scaling_factor(), 10 * OCTAS_PER_APT, user_yes_shares));
        assert!(no_buyin2 == math64::mul_div(constants::price_scaling_factor(), 5 * OCTAS_PER_APT, user_no_shares));
        assert!(yes_buyin > yes_buyin2); // first buyin was more expensive and the avg. price per share decreased

        // sell should not change avg buyin value
        market::sell_shares(user1, market_obj, true, 3 * OCTAS_PER_APT, 0);
        let (yes_buyin3, _) = market::user_buyin(market_obj, signer::address_of(user1));
        assert!(yes_buyin2 == yes_buyin3);
    }

    #[test(aptos_framework = @aptos_framework, panana = @panana, user1 = @user1, market_creator = @admin, user2 = @user2)]
    public fun test_lp_fees(aptos_framework: &signer, panana: &signer, user1: &signer, user2: &signer, market_creator: &signer) {
        let (burn_ref, mint_ref) = initialize_for_test(aptos_framework);
        market::init_test(aptos_framework, panana);

        let aptos_coin_metadata = *coin::paired_metadata<AptosCoin>().borrow();

        market::create_market(
            market_creator,
            aptos_coin_metadata,
            string::utf8(b"Will Panana be big?"),
            string::utf8(b"Great question with an obvious answer"),
            string::utf8(b"Always resolves to yes"),
            vector[string::utf8(b"https://panana.com")],
            0,
            100 * OCTAS_PER_APT,
            100 * OCTAS_PER_APT,
            0,
            0,
            5_000, // 50%
            0,
            0,
            0,
            false,
            true
        );
        let market_obj = market::market_by_id(0);

        let user_tokens = coin::coin_to_fungible_asset(coin::mint(50 * OCTAS_PER_APT, &mint_ref));
        aptos_account::deposit_fungible_assets(signer::address_of(user1), user_tokens);

        let user2_tokens = coin::coin_to_fungible_asset(coin::mint(200 * OCTAS_PER_APT, &mint_ref));
        aptos_account::deposit_fungible_assets(signer::address_of(user2), user2_tokens);
        coin::destroy_burn_cap(burn_ref);
        coin::destroy_mint_cap(mint_ref);

        let lp_fees = market::lp_fees(market_obj, signer::address_of(market_creator));
        assert!(lp_fees == 0);
        market::buy_shares(user1, market_obj, true, 10 * OCTAS_PER_APT, 0);
        let lp_fees = market::lp_fees(market_obj, signer::address_of(market_creator));
        assert!(lp_fees == 5 * OCTAS_PER_APT);

        market::add_liquidity(user2, market_obj, 200 * OCTAS_PER_APT, false);
        market::buy_shares(user1, market_obj, false, 18 * OCTAS_PER_APT, 0);
        let lp_fees = market::lp_fees(market_obj, signer::address_of(market_creator));
        assert!(lp_fees == 8 * OCTAS_PER_APT);
        let lp_fees = market::lp_fees(market_obj, signer::address_of(user2));
        assert!(lp_fees == 6 * OCTAS_PER_APT);
    }

    #[test(aptos_framework = @aptos_framework, panana = @panana, user1 = @user1, market_creator = @admin)]
    public fun test_sell_market_and_creator_fee(aptos_framework: &signer, panana: &signer, user1: &signer, market_creator: &signer) {
        let (burn_ref, mint_ref) = initialize_for_test(aptos_framework);
        market::init_test(aptos_framework, panana);

        let aptos_coin_metadata = *coin::paired_metadata<AptosCoin>().borrow();

        market::create_market(
            market_creator,
            aptos_coin_metadata,
            string::utf8(b"Will Panana be big?"),
            string::utf8(b"Great question with an obvious answer"),
            string::utf8(b"Always resolves to yes"),
            vector[string::utf8(b"https://panana.com")],
            0,
            100 * OCTAS_PER_APT,
            100 * OCTAS_PER_APT,
            0,
            0,
            0,
            1000,
            2000,
            0,
            false,
            true
        );
        let market_obj = market::market_by_id(0);

        let user_tokens = coin::coin_to_fungible_asset(coin::mint(50 * OCTAS_PER_APT, &mint_ref));
        aptos_account::deposit_fungible_assets(signer::address_of(user1), user_tokens);
        coin::destroy_burn_cap(burn_ref);
        coin::destroy_mint_cap(mint_ref);

        market::buy_shares(user1, market_obj, true, 5 * OCTAS_PER_APT, 0);

        let (market_fee, creator_fee, _) = market::fees(market_obj);
        assert!(market_fee == 0, 0);
        assert!(creator_fee == 0, 0);

        market::sell_shares(user1, market_obj, true, primary_fungible_store::balance(signer::address_of(user1), metadata(ASSET_SYMBOL_YES)), 0);

        let (market_fee, creator_fee, _) = market::fees(market_obj);
        assert!(market_fee == 5000_0000 - 1, 0);
        assert!(creator_fee == 1_0000_0000 - 1, 0);

        market::collect_fees(market_creator, market_obj);
        let fee_aptos_balance = primary_fungible_store::balance(signer::address_of(market_creator), aptos_coin_metadata);
        // Market fee recipient and creator are the same.
        assert!(fee_aptos_balance == 1_5000_0000 - 2, 0);
    }

    #[test(aptos_framework = @aptos_framework, panana = @panana, user1 = @user1, market_creator = @admin)]
    public fun test_price_after_resolution(aptos_framework: &signer, panana: &signer, user1: &signer, market_creator: &signer) {
        let (_burn_ref, _mint_ref) = initialize_for_test(aptos_framework);
        coin::destroy_burn_cap(_burn_ref);
        coin::destroy_mint_cap(_mint_ref);
        market::init_test(aptos_framework, panana);

        let aptos_coin_metadata = *coin::paired_metadata<AptosCoin>().borrow();

        market::create_market(
            market_creator,
            aptos_coin_metadata,
            string::utf8(b"Will Panana be big?"),
            string::utf8(b"Great question with an obvious answer"),
            string::utf8(b"Always resolves to yes"),
            vector[string::utf8(b"https://panana.com")],
            0,
            500 * OCTAS_PER_APT,
            500 * OCTAS_PER_APT,
            0,
            0,
            0,
            0,
            0,
            0,
            false,
            true
        );
        let market_obj = market::market_by_id(0);
        let (no_price, yes_price) = market::prices(market_obj);
        assert!(yes_price == 5000_0000);
        assert!(no_price == 5000_0000);

        market::resolve_market(market_creator, market_obj, metadata(ASSET_SYMBOL_YES));
        // price direct after resolution should be the same as the price before until fully resolved.
        let (no_price_after, yes_price_after) = market::prices(market_obj);
        assert!(yes_price == yes_price_after);
        assert!(no_price == no_price_after);

        // pass challenge time to make resolution final
        timestamp::update_global_time_for_test_secs(3 * 60 * 60 * 24 * 4 * 1000);

        // when resolution is final, the market prices should be unique
        let (yes_price, no_price) = market::prices(market_obj);
        assert!(yes_price == 1_0000_0000);
        assert!(no_price == 0);
    }

    #[test(aptos_framework = @aptos_framework, panana = @panana, user1 = @user1, market_creator = @admin)]
    public fun test_remove_liquidity(aptos_framework: &signer, panana: &signer, user1: &signer, market_creator: &signer) {
        let (burn_ref, mint_ref) = initialize_for_test(aptos_framework);
        market::init_test(aptos_framework, panana);

        let aptos_coin_metadata = *coin::paired_metadata<AptosCoin>().borrow();

        let creator_tokens = coin::coin_to_fungible_asset(coin::mint(600 * OCTAS_PER_APT, &mint_ref));
        aptos_account::deposit_fungible_assets(signer::address_of(market_creator), creator_tokens);

        market::create_market(
            market_creator,
            aptos_coin_metadata,
            string::utf8(b"Will Panana be big?"),
            string::utf8(b"Great question with an obvious answer"),
            string::utf8(b"Always resolves to yes"),
            vector[string::utf8(b"https://panana.com")],
            0,
            100 * OCTAS_PER_APT,
            600 * OCTAS_PER_APT,
            0,
            0,
            0,
            0,
            0,
            0,
            false,
            false,
        );
        let market_obj = market::market_by_id(0);
        let (lp_meta, lps_meta) = market::get_lp_tokens(market_obj);
        assert!(primary_fungible_store::balance (signer::address_of(market_creator),lp_meta) == 600 * OCTAS_PER_APT);

        let user_tokens = coin::coin_to_fungible_asset(coin::mint(100 * OCTAS_PER_APT, &mint_ref));
        aptos_account::deposit_fungible_assets(signer::address_of(user1), user_tokens);

        // let creator_tokens = coin::coin_to_fungible_asset(coin::mint(100 * OCTAS_PER_APT, &mint_ref));
        coin::destroy_burn_cap(burn_ref);
        coin::destroy_mint_cap(mint_ref);

                        market::withdraw_liquidity(market_creator, market_obj, 400 * OCTAS_PER_APT, false);
                        assert!(primary_fungible_store::balance (signer::address_of(market_creator),aptos_coin_metadata) == 400 * OCTAS_PER_APT);
        assert!(primary_fungible_store::balance(signer::address_of(market_creator), metadata(ASSET_SYMBOL_YES)) == 0);
        assert!(primary_fungible_store::balance(signer::address_of(market_creator), metadata(ASSET_SYMBOL_NO)) == 0);

        market::buy_shares(user1, market_obj, true, 100 * OCTAS_PER_APT,0);

        market::withdraw_liquidity(market_creator, market_obj, 100 * OCTAS_PER_APT, false);

        assert!(primary_fungible_store::balance(signer::address_of(market_creator),aptos_coin_metadata) == 466_6666_6666);
        let no_token = market::metadata(ASSET_SYMBOL_NO);
                assert!(primary_fungible_store::balance(signer::address_of(market_creator),no_token) == 83_3333_3334);


        market::resolve_market(market_creator, market_obj, metadata(ASSET_SYMBOL_YES));
        timestamp::update_global_time_for_test_secs(3 * 60 * 60 * 24 * 4 * 1000);

        assert!(primary_fungible_store::balance(signer::address_of(user1), aptos_coin_metadata) == 0);
        assert!(primary_fungible_store::balance(signer::address_of(user1), market::metadata(ASSET_SYMBOL_YES)) != 0);

        market::sell_shares(user1, market_obj, true, primary_fungible_store::balance(signer::address_of(user1), market::metadata(ASSET_SYMBOL_YES)), 0);

        assert!(primary_fungible_store::balance(signer::address_of(user1), aptos_coin_metadata) == 166_6666_6666);
        assert!(primary_fungible_store::balance(object_address(&market_obj), aptos_coin_metadata) == 66_6666_6668);

        market::withdraw_liquidity(market_creator, market_obj,  100 * OCTAS_PER_APT, false);
        // no tokens are worth 0 since market resolved to yes
        market::sell_shares(market_creator, market_obj, false, primary_fungible_store::balance(signer::address_of(market_creator),no_token), 0);
        assert!(primary_fungible_store::balance(signer::address_of(market_creator),no_token) == 0);

        // minor dust reimains in the pool due to integer arithmetic
        assert!(primary_fungible_store::balance(object_address(&market_obj), aptos_coin_metadata) == 2);
    }


    #[test(aptos_framework = @aptos_framework, panana = @panana, user1 = @user1, market_creator = @admin)]
    public fun test_challenge_market_success(aptos_framework: &signer, panana: &signer, user1: &signer, market_creator: &signer) {
        let (burn_ref, mint_ref) = initialize_for_test(aptos_framework);
        market::init_test(aptos_framework, panana);

        let aptos_coin_metadata = *coin::paired_metadata<AptosCoin>().borrow();

        let creator_tokens = coin::coin_to_fungible_asset(coin::mint(1000 * OCTAS_PER_APT, &mint_ref));
        aptos_account::deposit_fungible_assets(signer::address_of(market_creator), creator_tokens);

        market::create_market(
            market_creator,
            aptos_coin_metadata,
            string::utf8(b"Will Panana be big?"),
            string::utf8(b"Great question with an obvious answer"),
            string::utf8(b"Always resolves to yes"),
            vector[string::utf8(b"https://panana.com")],
            0,
            100 * OCTAS_PER_APT,
            1000 * OCTAS_PER_APT,
            0,
            0,
            0,
            0,
            0,
            0,
            false,
            false,
        );
        let market_obj = market::market_by_id(0);
        let (lp_meta, lps_meta) = market::get_lp_tokens(market_obj);

        let user_tokens = coin::coin_to_fungible_asset(coin::mint(1500 * OCTAS_PER_APT, &mint_ref));
        aptos_account::deposit_fungible_assets(signer::address_of(user1), user_tokens);

        coin::destroy_burn_cap(burn_ref);
        coin::destroy_mint_cap(mint_ref);

        market::buy_shares(user1, market_obj, true, 1000 * OCTAS_PER_APT,0);

        market::resolve_market(market_creator, market_obj, metadata(ASSET_SYMBOL_YES));

        // Test selling markets after resolution possible
        market::sell_shares(user1, market_obj, true, 750 * OCTAS_PER_APT, 0);

        market::challenge_market(user1, market_obj);

        // Test selling markets after challenging possible
        market::sell_shares(user1, market_obj, true, 100 * OCTAS_PER_APT, 0);

        // market creator is also oracle in this case; final resolution finished
        market::resolve_market(market_creator, market_obj, metadata(ASSET_SYMBOL_NO));

        // Test selling remaining shares
        market::sell_shares(user1, market_obj, true, primary_fungible_store::balance(signer::address_of(user1), market::metadata(ASSET_SYMBOL_YES)), 0);

        market::withdraw_liquidity(market_creator, market_obj,  1000 * OCTAS_PER_APT, false);

        // minor dust reimains in the pool due to integer arithmetic
        assert!(primary_fungible_store::balance(object_address(&market_obj), aptos_coin_metadata) == 3);
    }

    #[test(aptos_framework = @aptos_framework, panana = @panana, user1 = @user1, market_creator = @admin)]
    public fun test_challenge_market_failure(aptos_framework: &signer, panana: &signer, user1: &signer, market_creator: &signer) {
        let (burn_ref, mint_ref) = initialize_for_test(aptos_framework);
        market::init_test(aptos_framework, panana);

        let aptos_coin_metadata = *coin::paired_metadata<AptosCoin>().borrow();

        let creator_tokens = coin::coin_to_fungible_asset(coin::mint(1000 * OCTAS_PER_APT, &mint_ref));
        aptos_account::deposit_fungible_assets(signer::address_of(market_creator), creator_tokens);

        market::create_market(
            market_creator,
            aptos_coin_metadata,
            string::utf8(b"Will Panana be big?"),
            string::utf8(b"Great question with an obvious answer"),
            string::utf8(b"Always resolves to yes"),
            vector[string::utf8(b"https://panana.com")],
            0,
            100 * OCTAS_PER_APT,
            1000 * OCTAS_PER_APT,
            0,
            0,
            0,
            0,
            0,
            0,
            false,
            false,
        );
        let market_obj = market::market_by_id(0);
        let (lp_meta, lps_meta) = market::get_lp_tokens(market_obj);

        let user_tokens = coin::coin_to_fungible_asset(coin::mint(1500 * OCTAS_PER_APT, &mint_ref));
        aptos_account::deposit_fungible_assets(signer::address_of(user1), user_tokens);

        coin::destroy_burn_cap(burn_ref);
        coin::destroy_mint_cap(mint_ref);

        market::buy_shares(user1, market_obj, true, 1000 * OCTAS_PER_APT,0);

        market::resolve_market(market_creator, market_obj, metadata(ASSET_SYMBOL_YES));

        // Test selling markets after resolution possible
        market::sell_shares(user1, market_obj, true, 750 * OCTAS_PER_APT, 0);

        market::challenge_market(user1, market_obj);

        // Test selling markets after challenging possible
        market::sell_shares(user1, market_obj, true, 100 * OCTAS_PER_APT, 0);

        // market creator is also oracle in this case; final resolution finished
        market::resolve_market(market_creator, market_obj, metadata(ASSET_SYMBOL_YES));

        // Test selling remaining shares
        market::sell_shares(user1, market_obj, true, primary_fungible_store::balance(signer::address_of(user1), market::metadata(ASSET_SYMBOL_YES)), 0);

        market::withdraw_liquidity(market_creator, market_obj,  1000 * OCTAS_PER_APT, false);

        // minor dust reimains in the pool due to integer arithmetic
        assert!(primary_fungible_store::balance(object_address(&market_obj), aptos_coin_metadata) == 1);
    }

    #[test(aptos_framework = @aptos_framework, panana = @panana, user1 = @user1, market_creator = @admin)]
    public fun test_add_liquidity(aptos_framework: &signer, panana: &signer, user1: &signer, market_creator: &signer) {
        let (burn_ref, mint_ref) = initialize_for_test(aptos_framework);

        market::init_test(aptos_framework, panana);
        let aptos_coin_metadata = *coin::paired_metadata<AptosCoin>().borrow();

        market::create_market(
            market_creator,
            aptos_coin_metadata,
            string::utf8(b"Will Panana be big?"),
            string::utf8(b"Great question with an obvious answer"),
            string::utf8(b"Always resolves to yes"),
            vector[string::utf8(b"https://panana.com")],
            0,
            400 * OCTAS_PER_APT,
            400 * OCTAS_PER_APT,
            0,
            0,
            0,
            0,
            0,
            0,
            false,
            true,
        );
        let market_obj = market::market_by_id(0);
        let (lp_meta, lps_meta) = market::get_lp_tokens(market_obj);
        assert!(primary_fungible_store::balance (signer::address_of(market_creator),lps_meta) == 400 * OCTAS_PER_APT);

        let creator_tokens = coin::coin_to_fungible_asset(coin::mint(600 * OCTAS_PER_APT, &mint_ref));
        aptos_account::deposit_fungible_assets(signer::address_of(market_creator), creator_tokens);

        let user_tokens = coin::coin_to_fungible_asset(coin::mint(500 * OCTAS_PER_APT, &mint_ref));
        aptos_account::deposit_fungible_assets(signer::address_of(user1), user_tokens);

        coin::destroy_burn_cap(burn_ref);
        coin::destroy_mint_cap(mint_ref);

        // assert!(cpmm::liquidity(market::metadata(ASSET_SYMBOL_YES), market::metadata(ASSET_SYMBOL_NO)) == 400 * OCTAS_PER_APT);
        market::add_liquidity(market_creator, market_obj, 100 * OCTAS_PER_APT, true);

        // no tokens are transferred because liquidity is synthetic
        assert!(primary_fungible_store::balance(signer::address_of(market_creator),aptos_coin_metadata) == 600 * OCTAS_PER_APT);
        assert!(primary_fungible_store::balance(object_address(&market_obj), aptos_coin_metadata) == 0 * OCTAS_PER_APT);
        // assert!(cpmm::liquidity(market::metadata(ASSET_SYMBOL_YES), market::metadata(ASSET_SYMBOL_NO)) == 500 * OCTAS_PER_APT);
        let (yes_shares, no_shares) = market::shares(market_obj);
        assert!(yes_shares == 500 * OCTAS_PER_APT && no_shares == 500 * OCTAS_PER_APT);

        market::buy_shares(user1, market_obj, true, 500 * OCTAS_PER_APT, 0);
        let (yes_shares, no_shares) = market::shares(market_obj);
        assert!(yes_shares == 250 * OCTAS_PER_APT && no_shares == 1000 * OCTAS_PER_APT);

        assert!(primary_fungible_store::balance(object_address(&market_obj), aptos_coin_metadata) == 500 * OCTAS_PER_APT);

        market::add_liquidity(market_creator, market_obj, 100 * OCTAS_PER_APT, true);
        let (yes_shares, no_shares) = market::shares(market_obj);
        assert!(yes_shares == 275 * OCTAS_PER_APT && no_shares == 1100 * OCTAS_PER_APT);
        assert!(primary_fungible_store::balance(signer::address_of(market_creator), market::metadata(ASSET_SYMBOL_YES)) == 75 * OCTAS_PER_APT);
        assert!(primary_fungible_store::balance(signer::address_of(market_creator), market::metadata(ASSET_SYMBOL_NO)) == 0 * OCTAS_PER_APT); // no remainder
        assert!(primary_fungible_store::balance(signer::address_of(market_creator), lps_meta) == 550_0000_0000); // 500 of initial provisioning, 50 after providing another 100$
    }

    #[test(aptos_framework = @aptos_framework, panana = @panana, user1 = @user1, admin = @admin)]
    public fun test_create_market_fee(aptos_framework: &signer, panana: &signer, user1: &signer, admin: &signer) {
        let (burn_ref, mint_ref) = initialize_for_test(aptos_framework);

        market::init_test(aptos_framework, panana);
        let aptos_coin_metadata = *coin::paired_metadata<AptosCoin>().borrow();

        // user should get 400 APT for the initial iquidity and another 1 APT for market cration cost
        let creator_tokens = coin::coin_to_fungible_asset(coin::mint(201 * OCTAS_PER_APT, &mint_ref));
        aptos_account::deposit_fungible_assets(signer::address_of(user1), creator_tokens);
        // set market creation costs
        config::set_market_creation_cost(admin, aptos_coin_metadata, 1 * OCTAS_PER_APT);

        market::create_market(
            user1,
            aptos_coin_metadata,
            string::utf8(b"Will Panana be big?"),
            string::utf8(b"Great question with an obvious answer"),
            string::utf8(b"Always resolves to yes"),
            vector[string::utf8(b"https://panana.com")],
            0,
            400 * OCTAS_PER_APT,
            200 * OCTAS_PER_APT,
            0,
            0,
            0,
            0,
            0,
            0,
            false,
            false,
        );

        assert!(primary_fungible_store::balance(signer::address_of(user1), aptos_coin_metadata) == 0);
        // Panana is the address to send the fees to
        assert!(primary_fungible_store::balance(signer::address_of(admin), aptos_coin_metadata) == 1 * OCTAS_PER_APT);

        coin::destroy_burn_cap(burn_ref);
        coin::destroy_mint_cap(mint_ref);
    }

    #[test(aptos_framework = @aptos_framework, panana = @panana, user1 = @user1, user2 = @user2)]
    public fun test_buy_in_and_sell_simulate(aptos_framework: &signer, panana: &signer, user1: &signer, user2: &signer) {

        let share_output = market::simulate_buy_shares(1000 * OCTAS_PER_APT, 1000 * OCTAS_PER_APT, 5 * OCTAS_PER_APT);
        assert!(share_output == 9_9751_2437); // user has bought ~10 shares

        let (in_vault, out_vault) = cpmm::simulate_token_change(1000 * OCTAS_PER_APT, 1000 * OCTAS_PER_APT, 5 * OCTAS_PER_APT);
        let returned_money = market::simulate_sell_shares(out_vault, in_vault, share_output);
        assert!(returned_money == 5 * OCTAS_PER_APT - 1);
    }

    #[expected_failure(abort_code = market::E_SLIPPAGE)]
    #[test(aptos_framework = @aptos_framework, panana = @panana, user1 = @user1, market_creator = @admin)]
    public fun test_buy_in_slippage_error(aptos_framework: &signer, panana: &signer, user1: &signer, market_creator: &signer) {
        let (burn_ref, mint_ref) = initialize_for_test(aptos_framework);
        market::init_test(aptos_framework, panana);

        let aptos_coin_metadata = *coin::paired_metadata<AptosCoin>().borrow();

        market::create_market(
            market_creator,
            aptos_coin_metadata,
            string::utf8(b"Will Panana be big?"),
            string::utf8(b"Great question with an obvious answer"),
            string::utf8(b"Always resolves to yes"),
            vector[string::utf8(b"https://panana.com")],
            0,
            1000 * OCTAS_PER_APT,
            1000 * OCTAS_PER_APT,
            0,
            0,
            0,
            0,
            0,
            0,
            false,
            true
        );
        let market_obj = market::market_by_id(0);

        let user_tokens = coin::coin_to_fungible_asset(coin::mint(5 * OCTAS_PER_APT, &mint_ref));
        aptos_account::deposit_fungible_assets(signer::address_of(user1), user_tokens);
        coin::destroy_burn_cap(burn_ref);
        coin::destroy_mint_cap(mint_ref);

        market::buy_shares(user1, market_obj, true, 5 * OCTAS_PER_APT, 10 * OCTAS_PER_APT + 1);
    }

    #[expected_failure(abort_code = market::E_SLIPPAGE)]
    #[test(aptos_framework = @aptos_framework, panana = @panana, user1 = @user1, market_creator = @admin)]
    public fun test_sell_slippage_error(aptos_framework: &signer, panana: &signer, user1: &signer, market_creator: &signer) {
        let (burn_ref, mint_ref) = initialize_for_test(aptos_framework);
        market::init_test(aptos_framework, panana);

        let aptos_coin_metadata = *coin::paired_metadata<AptosCoin>().borrow();

        market::create_market(
            market_creator,
            aptos_coin_metadata,
            string::utf8(b"Will Panana be big?"),
            string::utf8(b"Great question with an obvious answer"),
            string::utf8(b"Always resolves to yes"),
            vector[string::utf8(b"https://panana.com")],
            0,
            1000 * OCTAS_PER_APT,
            1000 * OCTAS_PER_APT,
            0,
            0,
            0,
            0,
            0,
            0,
            false,
            true,
        );
        let market_obj = market::market_by_id(0);

        let user_tokens = coin::coin_to_fungible_asset(coin::mint(5 * OCTAS_PER_APT, &mint_ref));
        aptos_account::deposit_fungible_assets(signer::address_of(user1), user_tokens);
        coin::destroy_burn_cap(burn_ref);
        coin::destroy_mint_cap(mint_ref);

        market::buy_shares(user1, market_obj, true, 5 * OCTAS_PER_APT, 0); // 5 APT -> >=0.5 APT per Share -> ~10 shares
        market::sell_shares(user1, market_obj, true,primary_fungible_store::balance(signer::address_of(user1), metadata(ASSET_SYMBOL_YES)), 5_0000_0001);
    }

    #[expected_failure(abort_code = market::E_FROZEN)]
    #[test(aptos_framework = @aptos_framework, panana = @panana, user1 = @user1, market_creator = @admin)]
    public fun test_abort_frozen_market_operation(aptos_framework: &signer, panana: &signer, user1: &signer, market_creator: &signer) {
        let (burn_ref, mint_ref) = initialize_for_test(aptos_framework);
        market::init_test(aptos_framework, panana);

        let aptos_coin_metadata = *coin::paired_metadata<AptosCoin>().borrow();

        market::create_market(
            market_creator,
            aptos_coin_metadata,
            string::utf8(b"Will Panana be big?"),
            string::utf8(b"Great question with an obvious answer"),
            string::utf8(b"Always resolves to yes"),
            vector[string::utf8(b"https://panana.com")],
            0,
            1000 * OCTAS_PER_APT,
            1000 * OCTAS_PER_APT,
            0,
            0,
            0,
            0,
            0,
            0,
            true,
            true,
        );
        let market_obj = market::market_by_id(0);

        let user_tokens = coin::coin_to_fungible_asset(coin::mint(5 * OCTAS_PER_APT, &mint_ref));
        aptos_account::deposit_fungible_assets(signer::address_of(user1), user_tokens);
        coin::destroy_burn_cap(burn_ref);
        coin::destroy_mint_cap(mint_ref);

        market::buy_shares(user1, market_obj, true, 5 * OCTAS_PER_APT, 0); // buy is disabled if market is frozen
    }

    #[test_only]
    inline fun is_equal_or_off_by_one(i: u64, expected: u64): bool {
        i == expected || i + 1 == expected || (i >= 1 && i - 1 == expected)
    }

}
