#[test_only]
module panana::crypto_market_test {
    use aptos_std::debug;
    use aptos_framework::fungible_asset;
    use panana::crypto_market::crypto_series;
    #[test_only]
    use aptos_framework::object::object_address;
    #[test_only]
    use panana::crypto_market::CryptoMarketSeries;
    #[test_only]
    use std::option;
    #[test_only]
    use aptos_framework::coin::{BurnCapability, MintCapability};
    #[test_only]
    use aptos_framework::fungible_asset::Metadata;
    #[test_only]
    use aptos_framework::primary_fungible_store;
    #[test_only]
    use std::bcs::to_bytes;
    #[test_only]
    use panana::crypto_market;
    #[test_only]
    use aptos_framework::object::Object;
    #[test_only]
    use std::vector;
    #[test_only]
    use std::signer;
    #[test_only]
    use aptos_framework::aptos_account;
    #[test_only]
    use aptos_framework::aptos_coin::AptosCoin;
    #[test_only]
    use aptos_framework::coin;
    #[test_only]
    use aptos_framework::timestamp;
    #[test_only]
    use aptos_framework::account;
    #[test_only]
    use aptos_framework::aptos_coin::initialize_for_test;
    #[test_only]
    use aptos_framework::block;


    const FIRST_MARKET_TIMESTAMP: u64 = 1704067200;
    const OPEN_DURATION_SEC: u64 = 180;
    const MIN_BET: u64 = 10_000_000;
    const FEE_NUMERATOR: u64 = 300;

    #[test_only]
    fun init_market_controller(aptos_framework: &signer, controller: &signer, feed: vector<u8>): (Object<CryptoMarketSeries>, MintCapability<AptosCoin>, BurnCapability<AptosCoin>, Object<Metadata>) {
        // pyth
        crypto_market::init(controller);
        let (burn_cap, mint_cap) = initialize_for_test(aptos_framework);
        let paired_metadata = *option::borrow(&coin::paired_metadata<AptosCoin>());
        crypto_market::create_crypto_series(controller, paired_metadata, feed, OPEN_DURATION_SEC, MIN_BET, FEE_NUMERATOR, FIRST_MARKET_TIMESTAMP);
        let series_obj = crypto_market::crypto_series(paired_metadata, feed, OPEN_DURATION_SEC);

        (*option::borrow(&series_obj), mint_cap, burn_cap, paired_metadata)
    }

    #[test(aptos_framework = @aptos_framework, controller = @0x100, account = @0x200, account2 = @0x300, funding_account = @0x400)]
    fun test_bet_and_claim_rewards(controller: &signer, account: &signer, account2: &signer, funding_account: &signer, aptos_framework: &signer) {
        account::create_account_for_test(signer::address_of(aptos_framework));
        block::initialize_for_test(aptos_framework, 1);
        timestamp::set_time_has_started_for_testing(aptos_framework);


        let account_address = signer::address_of(account);
        let account2_address = signer::address_of(account2);

        let (config, mint, burn, metadata) = init_market_controller(aptos_framework, controller, to_bytes(&@0x999));
        let bet_up = true;
        let coins1 = coin::coin_to_fungible_asset(coin::mint<AptosCoin>(10_000_000 + 20_000_000 + 30_000_000 + 40_000_000, &mint));
        let coins2 = coin::coin_to_fungible_asset(coin::mint<AptosCoin>(40_000_000 + 50_000_000 + 50_000_000, &mint));
        let marketmaker_coins = coin::coin_to_fungible_asset(coin::mint<AptosCoin>(20_000_000, &mint));

        aptos_account::deposit_fungible_assets(signer::address_of(account), coins1);
        aptos_account::deposit_fungible_assets(signer::address_of(account2), coins2);
        aptos_account::deposit_fungible_assets(signer::address_of(funding_account), marketmaker_coins);

        coin::destroy_burn_cap(burn);
        coin::destroy_mint_cap(mint);

        primary_fungible_store::transfer(funding_account, metadata, object_address(&config), 20_000_000);

        timestamp::update_global_time_for_test_secs(FIRST_MARKET_TIMESTAMP);

        // acc 1 set 1_000_000_000
        // acc1 set 600_000_000 from winning pool
        crypto_market::place_bet(account, config, bet_up, 10_000_000);
        crypto_market::place_bet(account, config, bet_up, 20_000_000);
        crypto_market::place_bet(account, config, bet_up, 30_000_000);
        crypto_market::place_bet(account2, config, bet_up, 40_000_000);
        crypto_market::place_bet(account2, config, bet_up, 50_000_000);

        crypto_market::place_bet(account, config, !bet_up, 40_000_000);
        crypto_market::place_bet(account2, config, !bet_up, 50_000_000);

        let resolution_timestamp = FIRST_MARKET_TIMESTAMP + 2 * 180;
        timestamp::update_global_time_for_test_secs(resolution_timestamp);

        let (up_bets,down_bets,up_bets_sum,down_bets_sum, fee_vault_sum, vault_sum) = crypto_market::bets_data(config, 0);

        assert!(up_bets == 3, 0); // 1 up bet amount is from the AMM
        assert!(down_bets == 3, 0); // 1 down bet is from the AMM
        assert!(up_bets_sum == 160_000_000 / 100 * 97, 0,); // up bets sum is input -3% fee
        assert!(down_bets_sum == 100_000_000 / 100 * 97, 0); // down bets sum is input -3% fee
        assert!(fee_vault_sum == 260_000_000 / 100 * 3, 0); // fees
        assert!(vault_sum == 260_000_000 / 100 * 97, 0); // 2 amount is from the AMM

        let market_balance_total = 260_000_000; // all input bets + 2 amm bets
        let fee = market_balance_total / 100 * 3;
        let market_balance_without_fee = market_balance_total - fee;

        assert!(coin::balance<AptosCoin>(account_address) == 0, 1);
        assert!(primary_fungible_store::balance(object_address(&config), metadata) == fee, 0);
        crypto_market::claim_rewards_test(account, config, 0, 100, 200000000);

        let account_balance = coin::balance<AptosCoin>(account_address);
        assert!(account_balance == market_balance_without_fee * 6 / 16, 5); // 16 sum of all up bets incl. AMM

        let config_vault_balance = primary_fungible_store::balance(object_address(&config), metadata);
        assert!(config_vault_balance == fee + market_balance_without_fee * 1 / 16, 0); // 16 sum of all up bets incl. AMM

        let (_,_,_,_,_,vault_sum) = crypto_market::bets_data(config, 0);
        assert!(vault_sum == market_balance_without_fee - market_balance_without_fee * 7 / 16, 0);

        assert!(coin::balance<AptosCoin>(account2_address) == 0, 1);
        crypto_market::claim_rewards_test(account2, config, 0, 100, 200);

        let account2_balance = coin::balance<AptosCoin>(account2_address);
        assert!(account2_balance == market_balance_without_fee * 9 / 16, 5); // 16 sum of all up bets incl. AMM
        let (_,_,_,_,_,vault_sum) = crypto_market::bets_data(config, 0);
        assert!(vault_sum == 0, 0);
    }


    #[test(aptos_framework = @aptos_framework, controller = @0x100, account = @0x200, funding_account = @0x300)]
    fun test_place_bet_new_epoch(controller: &signer, account: &signer, aptos_framework: &signer, funding_account: &signer) {
        account::create_account_for_test(signer::address_of(aptos_framework));
        block::initialize_for_test(aptos_framework, 1);
        timestamp::set_time_has_started_for_testing(aptos_framework);

        let account_address = signer::address_of(account);

        let (config, mint, burn, metadata) = init_market_controller(aptos_framework, controller, to_bytes(&@0x999));
        let bet_up = true;

        let amount = MIN_BET;
        let coins = coin::coin_to_fungible_asset(coin::mint<AptosCoin>(1000000000, &mint));
        let marketmaker_coins = coin::coin_to_fungible_asset(coin::mint<AptosCoin>(1000000000, &mint));

        aptos_account::deposit_fungible_assets(signer::address_of(account), coins);
        aptos_account::deposit_fungible_assets(signer::address_of(funding_account), marketmaker_coins);

        coin::destroy_burn_cap(burn);
        coin::destroy_mint_cap(mint);

        primary_fungible_store::transfer(funding_account, metadata, object_address(&config), 10_0000_0000);

        timestamp::update_global_time_for_test_secs(FIRST_MARKET_TIMESTAMP);
        crypto_market::place_bet(account, config, bet_up, amount);
        timestamp::update_global_time_for_test_secs(FIRST_MARKET_TIMESTAMP + OPEN_DURATION_SEC);
        crypto_market::place_bet(account, config, bet_up, 2 * amount);

        let res = crypto_market::unclaimed_markets(account_address, config);
        assert!(vector::length(&res) == 2, 0);


        let (up_bets,down_bets,up_bets_sum,down_bets_sum,_,vault_sum) = crypto_market::bets_data(config, 0);
        let (up_bets2,down_bets2,up_bets_sum2,down_bets_sum2,_,vault_sum2) = crypto_market::bets_data(config, 1);


        assert!(up_bets == 2, 0);  // 1 up bet is from the automated deposit
        assert!(down_bets == 1, 0,); // 1 down bet is from the automated deposit
        assert!(up_bets_sum == (amount * 2) / 100 * 97, 0);  // 1 up bet amount is from the automated deposit
        assert!(down_bets_sum == amount / 100 * 97, 0); // 1 down bet amount is from the automated deposit
        assert!(vault_sum == (3 * amount) / 100 * 97, 0); // 1 down bet amount is from the automated deposit

        assert!(up_bets2 == 2, 0); // 1 up bet is from the automated deposit
        assert!(down_bets2 == 1, 0); // 1 down bet is from the automated deposit
        assert!(up_bets_sum2 == (3 * amount) / 100 * 97, 0); // 1 up bet sum is from the automated deposit
        assert!(down_bets_sum2 == amount / 100 * 97, 0); // 1 down bet amount is from the automated deposit
        assert!(vault_sum2 == (4 * amount) / 100 * 97, 0); // 1 down bet amount is from the automated deposit

        assert!(primary_fungible_store::balance(account_address, metadata) == 1000000000 - 3 * amount, 0);

        timestamp::update_global_time_for_test_secs(FIRST_MARKET_TIMESTAMP + 2 * OPEN_DURATION_SEC);
        crypto_market::claim_rewards_test(account, config, 0, 100, 200);
        timestamp::update_global_time_for_test_secs(FIRST_MARKET_TIMESTAMP + 3 * OPEN_DURATION_SEC);
        crypto_market::claim_rewards_test(account, config, 1, 100, 200);
        // Every new coin emission, the emitted coins will decrease by 20 * x, where x is the amount of how often the user claimed a winning market already.
    }

    #[test(aptos_framework = @aptos_framework, controller = @0x100, account = @0x200, funding_account = @0x300)]
    fun test_fee(controller: &signer, account: &signer, aptos_framework: &signer, funding_account: &signer) {
        account::create_account_for_test(signer::address_of(aptos_framework));
        block::initialize_for_test(aptos_framework, 1);
        timestamp::set_time_has_started_for_testing(aptos_framework);

        let account_address = signer::address_of(account);

        let (config, mint, burn, metadata) = init_market_controller(aptos_framework, controller, to_bytes(&@0x999));
        let bet_up = true;

        let amount = MIN_BET;
        let coins = coin::coin_to_fungible_asset(coin::mint<AptosCoin>(1000000000, &mint));

        aptos_account::deposit_fungible_assets(signer::address_of(account), coins);

        coin::destroy_burn_cap(burn);
        coin::destroy_mint_cap(mint);

        timestamp::update_global_time_for_test_secs(FIRST_MARKET_TIMESTAMP);
        crypto_market::place_bet(account, config, bet_up, amount);
        crypto_market::place_bet(account, config, !bet_up, 2 * amount);


        let (up_bets,down_bets,up_bets_sum,down_bets_sum,vault_fee,vault_sum) = crypto_market::bets_data(config, 0);


        assert!(up_bets == 1, 0);
        assert!(down_bets == 1, 0,);
        assert!(up_bets_sum == amount / 100 * 97, 0);
        assert!(down_bets_sum == (2*amount) / 100 * 97, 0);
        assert!(vault_fee == (3 * amount) / 100 * 3, 0);
        assert!(vault_sum == (3 * amount) / 100 * 97, 0);

        assert!(primary_fungible_store::balance(object_address(&config), metadata) == (3 * amount) / 100 * 3);
        assert!(primary_fungible_store::balance(signer::address_of(controller), metadata) == 0);
        crypto_market::withdraw_series_vault(controller, config, (3 * amount) / 100 * 3);
        assert!(primary_fungible_store::balance(object_address(&config), metadata) == 0);
        assert!(primary_fungible_store::balance(signer::address_of(controller), metadata) == (3 * amount) / 100 * 3);
    }

    #[test(aptos_framework = @aptos_framework, controller = @0x100, account = @0x200)]
    fun test_claim_looser(controller: &signer, account: &signer, aptos_framework: &signer) {
        account::create_account_for_test(signer::address_of(aptos_framework));
        block::initialize_for_test(aptos_framework, 1);
        timestamp::set_time_has_started_for_testing(aptos_framework);

        let account_address = signer::address_of(account);

        let (crypto_series, mint, burn, metadata) = init_market_controller(aptos_framework, controller, to_bytes(&@0x999));
        let amount = MIN_BET;
        let coins = coin::coin_to_fungible_asset(coin::mint<AptosCoin>(amount, &mint));

        aptos_account::deposit_fungible_assets(signer::address_of(account), coins);

        coin::destroy_burn_cap(burn);
        coin::destroy_mint_cap(mint);

        timestamp::update_global_time_for_test_secs(FIRST_MARKET_TIMESTAMP);
        crypto_market::place_bet(account, crypto_series, true, amount);
        timestamp::update_global_time_for_test_secs(FIRST_MARKET_TIMESTAMP + 2 * OPEN_DURATION_SEC);
        crypto_market::claim_rewards_test(account, crypto_series, 0, 200, 100);

        assert!(primary_fungible_store::balance(account_address, metadata) == 0, 0);
    }

    #[expected_failure(abort_code = crypto_market::E_BET_TOO_LOW)]
    #[test(aptos_framework = @aptos_framework, controller = @0x100, account = @0x200)]
    fun test_place_bet_too_low(controller: &signer, account: &signer, aptos_framework: &signer) {
        account::create_account_for_test(signer::address_of(aptos_framework));
        block::initialize_for_test(aptos_framework, 1);
        timestamp::set_time_has_started_for_testing(aptos_framework);

        let (config, mint, burn, metadata) = init_market_controller(aptos_framework, controller, to_bytes(&@0x999));
        let bet_up = true;
        let coins = coin::coin_to_fungible_asset(coin::mint<AptosCoin>(1000000000, &mint));

        aptos_account::deposit_fungible_assets(signer::address_of(account), coins);

        coin::destroy_burn_cap(burn);
        coin::destroy_mint_cap(mint);
        timestamp::update_global_time_for_test_secs(FIRST_MARKET_TIMESTAMP);
        crypto_market::place_bet(account, config, bet_up, MIN_BET - 1);
    }

    #[expected_failure(abort_code = crypto_market::E_NO_REWARDS)]
    #[test(aptos_framework = @aptos_framework, controller = @0x100, account = @0x200)]
    fun test_claim_running_market(controller: &signer, account: &signer, aptos_framework: &signer) {
        account::create_account_for_test(signer::address_of(aptos_framework));
        block::initialize_for_test(aptos_framework, 1);
        timestamp::set_time_has_started_for_testing(aptos_framework);

        let account_address = signer::address_of(account);
        let (config, mint, burn, metadata) = init_market_controller(aptos_framework, controller, to_bytes(&@0x999));

        let coins = coin::coin_to_fungible_asset(coin::mint<AptosCoin>(10_000_000, &mint));
        aptos_account::deposit_fungible_assets(account_address, coins);
        coin::destroy_burn_cap(burn);
        coin::destroy_mint_cap(mint);

        timestamp::update_global_time_for_test_secs(FIRST_MARKET_TIMESTAMP);

        crypto_market::place_bet(account, config,true, 10_000_000);
        crypto_market::claim_rewards_test(account, config, 0, 100, 200);
    }

    #[test(aptos_framework = @aptos_framework, controller = @0x100, account = @0x200, account2 = @0x300)]
    fun test_fund_and_withdraw_crypto_series(controller: &signer, account: &signer, account2: &signer, aptos_framework: &signer) {
        let account_address = signer::address_of(account);
        let account2_address = signer::address_of(account2);
        let (crypto_series, mint, burn, metadata) = init_market_controller(aptos_framework, controller, to_bytes(&@0x999));

        let config_coins = coin::coin_to_fungible_asset(coin::mint<AptosCoin>(200_000_000, &mint));
        aptos_account::deposit_fungible_assets(account_address, config_coins);
        coin::destroy_burn_cap(burn);
        coin::destroy_mint_cap(mint);

        primary_fungible_store::transfer(account, metadata, object_address(&crypto_series), 200_000_000);

        crypto_market::withdraw_series_vault(controller, crypto_series, 50_000_000);
        assert!(primary_fungible_store::balance(object_address(&crypto_series), metadata) == 150_000_000, 0);
        assert!(primary_fungible_store::balance(signer::address_of(controller), metadata) == 50_000_000, 0);
    }


    #[expected_failure(abort_code = crypto_market::E_UNAUTHORIZED)]
    #[test(aptos_framework = @aptos_framework, controller = @0x100, account = @0x200)]
    fun test_error_not_owner_withdraw(controller: &signer, account: &signer, aptos_framework: &signer) {
        let account_address = signer::address_of(account);
        let (config, mint, burn, metadata) = init_market_controller(aptos_framework, controller, to_bytes(&@0x999));

        let config_coins = coin::coin_to_fungible_asset(coin::mint<AptosCoin>(200_000_000, &mint));
        aptos_account::deposit_fungible_assets(account_address, config_coins);
        coin::destroy_burn_cap(burn);
        coin::destroy_mint_cap(mint);

        primary_fungible_store::transfer(account, metadata, object_address(&config), 200_000_000);
        crypto_market::withdraw_series_vault(account, config, 50_000_000);
    }
}
