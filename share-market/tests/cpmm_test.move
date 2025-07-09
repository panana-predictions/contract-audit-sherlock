module panana::cpmm_test {
    #[test_only]
    use std::option;
    #[test_only]
    use std::signer;
    #[test_only]
    use std::string::utf8;
    #[test_only]
    use aptos_std::math64;
    #[test_only]
    use aptos_std::pool_u64::buy_in;
    #[test_only]
    use aptos_framework::event;
    #[test_only]
    use aptos_framework::fungible_asset;
    #[test_only]
    use aptos_framework::fungible_asset::{MintRef, TransferRef, BurnRef, mint_ref_metadata};
    #[test_only]
    use aptos_framework::object;
    #[test_only]
    use aptos_framework::primary_fungible_store;
    #[test_only]
    use panana::cpmm;
    #[test_only]
    use panana::cpmm::{create_liquidity_removed_event,
        create_liquidity_added_event, create_pool_created_event, create_swap_event
    };
    #[test_only]
    use panana::cpmm_utils;

    const ASSET_NAME_A: vector<u8> = b"Yes";
    const ASSET_SYMBOL_A: vector<u8> = b"YES";

    const ASSET_NAME_B: vector<u8> = b"No";
    const ASSET_SYMBOL_B: vector<u8> = b"NO";

    const ASSET_NAME_C: vector<u8> = b"AA";
    const ASSET_SYMBOL_C: vector<u8> = b"AA";

    const ASSET_SYMBOL_LP: vector<u8> = b"LP";
    const ASSET_SYMBOL_LPS: vector<u8> = b"LPS";

    #[test(panana = @panana)]
    public fun test_create_liquidity_pool(panana: &signer) {
        cpmm::init_test(panana);
        let (mint_a, _, _, mint_b, _, _) = init_tokens(panana);
        let metadata_a = fungible_asset::mint_ref_metadata(&mint_a);
        let metadata_b = fungible_asset::mint_ref_metadata(&mint_b);

        let initial_a_liquidity = fungible_asset::mint(&mint_a, 1000_0000_0000);
        let initial_b_liquidity = fungible_asset::mint(&mint_b, 1000_0000_0000);

        let (lp_tokens, pool) = cpmm::create_liquidity_pool(initial_a_liquidity, initial_b_liquidity, ASSET_SYMBOL_LP, ASSET_SYMBOL_LPS, false);
        assert!(fungible_asset::amount(&lp_tokens) == 1000_0000_0000);
        primary_fungible_store::deposit(signer::address_of(panana), lp_tokens); // deposit assets so it's not dropped

        let prices = cpmm::token_price(pool);
        let price_a = *prices.borrow(&metadata_a);
        let price_b = *prices.borrow(&metadata_b);
        assert!(price_a == 5000_0000, 0);
        assert!(price_b == 5000_0000, 0);

        let shares = cpmm::available_tokens(pool);
        let shares_a = *shares.borrow(&metadata_a);
        let shares_b = *shares.borrow(&metadata_b);
        assert!(shares_a == 1000_0000_0000, 0);
        assert!(shares_b == 1000_0000_0000, 0);
    }

    struct BuyInCase has drop {
        amount: u64,
        is_token_b: bool,
        expected_shares_a: u64,
        expected_shares_b: u64,
    }

    #[test(panana = @panana)]
    public fun test_buy_in(panana: &signer) {
        cpmm::init_test(panana);
        let (mint_a, _, burn_a, mint_b, _, burn_b) = init_tokens(panana);
        let metadata_a = fungible_asset::mint_ref_metadata(&mint_a);
        let metadata_b = fungible_asset::mint_ref_metadata(&mint_b);

        // Initialize liquidity pool
        let initial_a_liquidity = fungible_asset::mint(&mint_a, 1000_0000_0000);
        let initial_b_liquidity = fungible_asset::mint(&mint_b, 1000_0000_0000);
        let (lp_tokens, pool) = cpmm::create_liquidity_pool(initial_a_liquidity, initial_b_liquidity, ASSET_SYMBOL_LP, ASSET_SYMBOL_LPS, false);
        assert!(fungible_asset::amount(&lp_tokens) == 1000_0000_0000);
        primary_fungible_store::deposit(signer::address_of(panana), lp_tokens); // deposit assets so it's not dropped



        // Define buy-in test cases (amount in A or B, expected shares_a, expected shares_b)
        // Define buy-in test cases
        let buy_in_cases: vector<BuyInCase> = vector[
            BuyInCase { amount: 10_0000_0000, is_token_b: false, expected_shares_a: 1010_0000_0000, expected_shares_b: 990_0990_0991 },
            BuyInCase { amount: 100_0000_0000, is_token_b: true, expected_shares_a: 917_3478_6558, expected_shares_b: 1090_0990_0991 },
            BuyInCase { amount: 20_0000_0000, is_token_b: false, expected_shares_a: 937_3478_6558, expected_shares_b: 1066_8397_8994 },
            BuyInCase { amount: 200_0000_0000, is_token_b: true, expected_shares_a: 789_3657_9666, expected_shares_b: 1266_8397_8994 },
            BuyInCase { amount: 50_0000_0000, is_token_b: false, expected_shares_a: 839_3657_9666, expected_shares_b: 1191_3756_8389 },
            BuyInCase { amount: 500_0000_0000, is_token_b: true, expected_shares_a: 591_2347_0295, expected_shares_b: 1691_3756_8389 },
            BuyInCase { amount: 30_0000_0000, is_token_b: false, expected_shares_a: 621_2347_0295, expected_shares_b: 1609_6975_8337 },
            BuyInCase { amount: 300_0000_0000, is_token_b: true, expected_shares_a: 523_6431_1960, expected_shares_b: 1909_6975_8337 },
        ];

        let i = 0;
        while (i < buy_in_cases.length()) {
            let BuyInCase{amount, is_token_b, expected_shares_a, expected_shares_b} = buy_in_cases.borrow(i);

            if (*is_token_b) {
                let buy_in = fungible_asset::mint(&mint_b, *amount);
                let yes_shares = cpmm::swap(pool, buy_in, 0);
                fungible_asset::burn(&burn_a, yes_shares);
            } else {
                let buy_in = fungible_asset::mint(&mint_a, *amount);
                let no_shares = cpmm::swap(pool, buy_in, 0);
                fungible_asset::burn(&burn_b, no_shares);
            };

            // Get updated shares
            let shares = cpmm::available_tokens(pool);
            let shares_a = *shares.borrow(&metadata_a);
            let shares_b = *shares.borrow(&metadata_b);

            // Validate expected shares
            assert!(shares_a == *expected_shares_a, 0);
            assert!(shares_b == *expected_shares_b, 0);

            i = i + 1;
        }
    }

    #[test(panana = @panana)]
    public fun test_buy_sell(panana: &signer) {
        cpmm::init_test(panana);
        let (mint_a, _, burn_a, mint_b, _, burn_b) = init_tokens(panana);

        // Initialize liquidity pool
        let initial_a_liquidity = fungible_asset::mint(&mint_a, 1000_0000_0000);
        let initial_b_liquidity = fungible_asset::mint(&mint_b, 1000_0000_0000);
        let (lp_tokens, pool) = cpmm::create_liquidity_pool(initial_a_liquidity, initial_b_liquidity, ASSET_SYMBOL_LP, ASSET_SYMBOL_LPS, false);
        let meta_a = fungible_asset::mint_ref_metadata(&mint_a);
        let meta_b = fungible_asset::mint_ref_metadata(&mint_b);
        let (meta_lp, meta_lps) = cpmm::lp_tokens(pool);
        assert!(event::was_event_emitted(&create_pool_created_event(pool, meta_a, meta_b, meta_lp, meta_lps, 1000_0000_0000, 1000_0000_0000, 1000_0000_0000, false)));

        assert!(fungible_asset::amount(&lp_tokens) == 1000_0000_0000);
        primary_fungible_store::deposit(signer::address_of(panana), lp_tokens); // deposit assets so it's not dropped

        let buy_in_money = 12_3456_7890;

        let prices = cpmm::token_price(pool);
        let price_a = *prices.borrow(&meta_a);
        let buy_in_share_amount = math64::mul_div(buy_in_money, 1_0000_0000, price_a);

        let b_shares = fungible_asset::mint(&mint_b, buy_in_share_amount);
        let a_shares = cpmm::swap(pool, b_shares, 0);
        assert!(event::was_event_emitted(&create_swap_event(pool, meta_b, meta_a, buy_in_share_amount, 24_0963_8532)));

        assert!(fungible_asset::amount(&a_shares) == 24_0963_8532, 0);

        let b_shares = cpmm::swap(pool, a_shares, 0);
        let prices = cpmm::token_price(pool);
        let price_b = *prices.borrow(&meta_b);
        let payout = math64::mul_div(fungible_asset::amount(&b_shares), price_b, 1_0000_0000);

        assert!(buy_in_money - payout == 26, 0);

        fungible_asset::burn(&burn_b, b_shares);
    }

    #[test(panana = @panana)]
    public fun test_remove_liquidity(panana: &signer) {
        cpmm::init_test(panana);
        let (mint_a, _, burn_a, mint_b, _, burn_b) = init_tokens(panana);

        // Initialize liquidity pool
        let initial_a_liquidity = fungible_asset::mint(&mint_a, 600_0000_0000);
        let initial_b_liquidity = fungible_asset::mint(&mint_b, 600_0000_0000);
        let (lp_tokens, pool) = cpmm::create_liquidity_pool(initial_a_liquidity, initial_b_liquidity, ASSET_SYMBOL_LP, ASSET_SYMBOL_LPS,  false);
        let meta_a = fungible_asset::mint_ref_metadata(&mint_a);
        let meta_b = fungible_asset::mint_ref_metadata(&mint_b);
        let meta_lp = fungible_asset::metadata_from_asset(&lp_tokens);
        let (meta_lp, meta_lps) = cpmm::lp_tokens(pool);

        assert!(fungible_asset::amount(&lp_tokens) == 600_0000_0000);
        let remove_lp_tokens_1 = fungible_asset::extract(&mut lp_tokens, 100_0000_0000);
        let remove_lp_tokens_2 = fungible_asset::extract(&mut lp_tokens, 100_0000_0000);
        let remove_lp_tokens_3 = fungible_asset::extract(&mut lp_tokens, 350_0000_0000);
        primary_fungible_store::deposit(signer::address_of(panana), lp_tokens); // deposit assets so it's not dropped


        let prices = cpmm::token_price(pool);
        let (token_a, token_b) = cpmm::remove_liquidity(pool, remove_lp_tokens_1);
        let prices_new = cpmm::token_price(pool);
        assert!(*prices.borrow(&meta_a) == *prices_new.borrow(&meta_a) && *prices.borrow(&meta_b) == *prices_new.borrow(&meta_b));
        assert!(fungible_asset::amount(&token_a) == 100_0000_0000);
        assert!(fungible_asset::amount(&token_b) == 100_0000_0000);
        fungible_asset::burn(&burn_a, token_a);
        fungible_asset::burn(&burn_b, token_b);

        let a_swap_tokens = fungible_asset::mint(&mint_a, 500_0000_0000);
        let b_out = cpmm::swap(pool, a_swap_tokens, 0);
        fungible_asset::burn(&burn_b, b_out);


        let prices = cpmm::token_price(pool);
        let (token_a, token_b) = cpmm::remove_liquidity(pool, remove_lp_tokens_2);
        assert!(event::was_event_emitted(&create_liquidity_removed_event(pool, meta_a, meta_b, meta_lp, meta_lps, 200_0000_0000, 50_0000_0000, 100_0000_0000, false)));
        let prices_new = cpmm::token_price(pool);
        assert!(*prices.borrow(&meta_a) == *prices_new.borrow(&meta_a) && *prices.borrow(&meta_b) == *prices_new.borrow(&meta_b));
        assert!(fungible_asset::amount(&token_a) == 200_0000_0000);
        assert!(fungible_asset::amount(&token_b) == 50_0000_0000);
        fungible_asset::burn(&burn_a, token_a);
        fungible_asset::burn(&burn_b, token_b);


        let prices = cpmm::token_price(pool);
        let (token_a, token_b) = cpmm::remove_liquidity(pool, remove_lp_tokens_3);
        let prices_new = cpmm::token_price(pool);
        assert!(*prices.borrow(&meta_a) == *prices_new.borrow(&meta_a) && *prices.borrow(&meta_b) == *prices_new.borrow(&meta_b));
        assert!(fungible_asset::amount(&token_a) == 700_0000_0000);
        assert!(fungible_asset::amount(&token_b) == 175_0000_0000);
        fungible_asset::burn(&burn_a, token_a);
        fungible_asset::burn(&burn_b, token_b);
    }

    #[test(panana = @panana)]
    public fun test_add_liquidity(panana: &signer) {
        cpmm::init_test(panana);
        let (mint_a, _, burn_a, mint_b, _, burn_b) = init_tokens(panana);

        // Initialize liquidity pool
        let initial_a_liquidity = fungible_asset::mint(&mint_a, 500_0000_0000);
        let initial_b_liquidity = fungible_asset::mint(&mint_b, 500_0000_0000);
        let (lp_tokens, pool) = cpmm::create_liquidity_pool(initial_a_liquidity, initial_b_liquidity, ASSET_SYMBOL_LP, ASSET_SYMBOL_LPS, false);

        let (meta_lp, meta_lps) = cpmm::lp_tokens(pool);
        primary_fungible_store::deposit(signer::address_of(panana), lp_tokens); // deposit assets so it's not dropped
        let meta_a = fungible_asset::mint_ref_metadata(&mint_a);
        let meta_b = fungible_asset::mint_ref_metadata(&mint_b);

        let prices = cpmm::token_price(pool);
        let add_a_liquidity = fungible_asset::mint(&mint_a, 100_0000_0000);
        let add_b_liquidity = fungible_asset::mint(&mint_b, 100_0000_0000);
        let (lp_token, token_a, token_b) = cpmm::add_liquidity(pool, add_a_liquidity, add_b_liquidity, false);
        assert!(event::was_event_emitted(&create_liquidity_added_event(pool, meta_a, meta_b, meta_lp, meta_lps, 100_0000_0000, 100_0000_0000, 100_0000_0000, false)));
        let prices_new = cpmm::token_price(pool);
        assert!(*prices.borrow(&meta_a) == *prices_new.borrow(&meta_a) && *prices.borrow(&meta_b) == *prices_new.borrow(&meta_b));
        assert!(fungible_asset::amount(&lp_token) == 100_0000_0000);
        assert!(fungible_asset::amount(&token_a) == 0); // 100% of tokens should be consumed
        assert!(fungible_asset::amount(&token_b) == 0); // 100% of tokens should be consumed
        primary_fungible_store::deposit(signer::address_of(panana), lp_token); // deposit assets so it's not dropped
        fungible_asset::burn(&burn_a, token_a);
        fungible_asset::burn(&burn_b, token_b);

        let a_swap_tokens = fungible_asset::mint(&mint_a, 500_0000_0000);
        let b_out = cpmm::swap(pool, a_swap_tokens, 0);
        fungible_asset::burn(&burn_b, b_out);

        let prices = cpmm::token_price(pool);
        let add_a_liquidity = fungible_asset::mint(&mint_a, 100_0000_0000);
        let add_b_liquidity = fungible_asset::mint(&mint_b, 100_0000_0000);
        let (lp_token, token_a, token_b) = cpmm::add_liquidity(pool, add_a_liquidity, add_b_liquidity, false);
        let prices_new = cpmm::token_price(pool);
        assert!(*prices.borrow(&meta_a) == *prices_new.borrow(&meta_a) && *prices.borrow(&meta_b) == *prices_new.borrow(&meta_b));
        assert!(fungible_asset::amount(&lp_token) == 54_5454_5453);
        assert!(fungible_asset::amount(&token_a) == 0); // 100% of tokens should be consumed
        assert!(fungible_asset::amount(&token_b) == 70_2479_3389); // remaining tokens should be returned
        primary_fungible_store::deposit(signer::address_of(panana), lp_token); // deposit assets so it's not dropped
        fungible_asset::burn(&burn_a, token_a);
        fungible_asset::burn(&burn_b, token_b);

        let prices = cpmm::token_price(pool);
        let add_a_liquidity = fungible_asset::mint(&mint_a, 1000_0000_0000);
        let add_b_liquidity = fungible_asset::mint(&mint_b, 1_0000_0000);
        let (lp_token, token_a, token_b) = cpmm::add_liquidity(pool, add_a_liquidity, add_b_liquidity, false);
        let prices_new = cpmm::token_price(pool);
        assert!(*prices.borrow(&meta_a) == *prices_new.borrow(&meta_a) && *prices.borrow(&meta_b) == *prices_new.borrow(&meta_b));
        assert!(fungible_asset::amount(&lp_token) == 1_8333_3333);
        assert!(fungible_asset::amount(&token_a) == 996_6388_8889); // 100% of tokens should be consumed
        assert!(fungible_asset::amount(&token_b) == 0); // remaining tokens should be returned
        primary_fungible_store::deposit(signer::address_of(panana), lp_token); // deposit assets so it's not dropped
        fungible_asset::burn(&burn_a, token_a);
        fungible_asset::burn(&burn_b, token_b);
    }

    #[test_only]
    fun compute_n1_n2(x: u64, y: u64, n: u64): (u64, u64) {
        let n1 = math64::mul_div(x, n, x+y);

        let n2 = n - n1;

        return (n1, n2)
    }

    #[test_only]
    fun init_tokens(account: &signer): (MintRef, TransferRef, BurnRef, MintRef, TransferRef, BurnRef) {
        let (mint_a, transfer_a, burn_a) = create_token(account, ASSET_NAME_A, ASSET_SYMBOL_A);
        let (mint_b, transfer_b, burn_b) = create_token(account, ASSET_NAME_B, ASSET_SYMBOL_B);

        let (meta_a, meta_b) = cpmm_utils::order_token_metadata(
            fungible_asset::mint_ref_metadata(&mint_a),
            fungible_asset::mint_ref_metadata(&mint_b)
        );
        if (meta_a == mint_ref_metadata(&mint_a)) {
            (mint_a, transfer_a, burn_a, mint_b, transfer_b, burn_b)
        } else {
            (mint_b, transfer_b, burn_b, mint_a, transfer_a, burn_a)
        }

    }

    #[test_only]
    fun create_token(
        account: &signer,
        asset_name: vector<u8>,
        asset_symbol: vector<u8>
    ): (MintRef, TransferRef, BurnRef) {
        let constructor_ref = &object::create_named_object(account, asset_name);
        primary_fungible_store::create_primary_store_enabled_fungible_asset(
            constructor_ref,
            option::none(),
            utf8(asset_name),
            utf8(asset_symbol),
            8,
            utf8(b"http://example.com/favicon.ico"),
            utf8(b"http://example.com"),
        );

        let mint_ref = fungible_asset::generate_mint_ref(constructor_ref);
        let burn_ref = fungible_asset::generate_burn_ref(constructor_ref);
        let transfer_ref = fungible_asset::generate_transfer_ref(constructor_ref);
        (mint_ref, transfer_ref, burn_ref)
    }
}
