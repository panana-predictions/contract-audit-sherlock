module panana::config {
    use std::option::Option;
    use std::signer;
    use aptos_std::smart_table;
    use aptos_framework::fungible_asset::Metadata;
    use aptos_framework::object::Object;

    const E_UNAUTHORIZED: u64 = 0;

    /// Market Config contains global configuration.
    /// Important addresses like the admin and resolver are contained in this global config, as well as
    /// default values for the markets, which can be overwritten by each individual market.
    enum MarketConfig has key {
        V1 {
            // The admin is the most privileged role in the contract
            admin: address,
            // The resolver can only resolve marekts
            resolver: address,
            // The resolution oracle has the final say in challenged markets
            resolution_oracle: address,

            // Default duration until the market resolution can be seen as final/cannot be challenged anymore
            default_challenge_duration_sec: u64,
            // Default costs to challenge a market depending on the market's asset type
            default_challenge_costs: smart_table::SmartTable<Object<Metadata>, u64>,
            // A map that contains the minimum liquidity to launch a market, depending on the market's asset type
            default_min_liquidity_required: smart_table::SmartTable<Object<Metadata>, u64>,
            // Costs to create a new market, depending on the market's asset type
            market_creation_cost: smart_table::SmartTable<Object<Metadata>, u64>,

            // Address to send the market fees to
            market_fee_address: address,

            // Global freeze to stop all market transactions
            is_frozen: bool,
        }
    }

    fun init_module(account: &signer) {
        move_to(account, MarketConfig::V1 {
            // Set all values to admin per default
            // Can be changed by the admin after deployment
            resolver: @admin,
            admin: @admin,
            resolution_oracle: @admin,
            default_challenge_duration_sec: 60 * 60 * 24 * 3, // 3 days in seconds
            default_challenge_costs: smart_table::new(),
            default_min_liquidity_required: smart_table::new(),
            market_creation_cost: smart_table::new(),
            is_frozen: false,
            market_fee_address: @admin,
        });
    }

    /// Update the global state. Only admin can do so.
    public entry fun update_global_state(
        account: &signer,
        admin: Option<address>,
        resolver: Option<address>,
        resolution_oracle: Option<address>,
        challenge_duration_sec: Option<u64>,
        is_frozen: Option<bool>,
        market_fee_address: Option<address>
    ) acquires MarketConfig {
        assert_admin(account);

        let global_state = borrow_global_mut<MarketConfig>(@panana);
        global_state.admin = *admin.borrow_with_default(&global_state.admin);
        global_state.resolver = *resolver.borrow_with_default(&global_state.resolver);
        global_state.resolution_oracle = *resolution_oracle.borrow_with_default(&global_state.resolution_oracle);
        global_state.default_challenge_duration_sec = *challenge_duration_sec.borrow_with_default(
            &global_state.default_challenge_duration_sec
        );
        global_state.is_frozen = *is_frozen.borrow_with_default(&global_state.is_frozen);
        global_state.market_fee_address = *market_fee_address.borrow_with_default(&global_state.market_fee_address);
    }

    /// The minimum liquidity for each market specifies the amount of tokens that need to be provided as liquidity
    /// to become an open market where users can participate. The liquidity is different for each asset, allowing
    /// for markets with different asset types (APT, USDC, ...) to have distinct min liquidity requirements.
    /// Because 1000 APT !== 1000 USDC
    public entry fun set_default_min_liquidity_for_asset(
        account: &signer,
        asset: Object<Metadata>,
        min_liq: u64
    ) acquires MarketConfig {
        assert_admin(account);
        let global_state = borrow_global_mut<MarketConfig>(@panana);
        global_state.default_min_liquidity_required.upsert(asset, min_liq);
    }

    /// Specify the default amount of tokens required to challenge a market. The cost is different for each asset, allowing
    /// for markets with different asset types (APT, USDC, ...) to have distinct challenge costs.
    /// Because 1000 APT !== 1000 USDC
    public entry fun set_default_challenge_costs(
        account: &signer,
        asset: Object<Metadata>,
        challenge_cost: u64
    ) acquires MarketConfig {
        assert_admin(account);
        let global_state = borrow_global_mut<MarketConfig>(@panana);
        global_state.default_challenge_costs.upsert(asset, challenge_cost);
    }

    /// Specify the cost to create a new market. The cost is different for each asset, allowing
    /// for markets with different asset types (APT, USDC, ...) to have distinct creation costs.
    /// Because 1000 APT !== 1000 USDC
    public entry fun set_market_creation_cost(
        account: &signer,
        asset: Object<Metadata>,
        creation_cost: u64
    ) acquires MarketConfig {
        assert_admin(account);
        let global_state = borrow_global_mut<MarketConfig>(@panana);
        global_state.market_creation_cost.upsert(asset, creation_cost);
    }


    /// Helper function to ensure caller is admin
    public fun assert_admin(caller: &signer) acquires MarketConfig {
        let config = borrow_global<MarketConfig>(@panana);
        assert!(signer::address_of(caller) == config.admin, E_UNAUTHORIZED);
    }

    /// Get the default min required liquidity to run a marketm, depending on the asset
    #[view]
    public fun default_min_liquidity_required(meta: Object<Metadata>): u64 acquires MarketConfig {
        let config = borrow_global<MarketConfig>(@panana);
        *config.default_min_liquidity_required.borrow_with_default(meta, &0)
    }

    /// Get the default challenge costs depending on the asset
    #[view]
    public fun default_challenge_costs(meta: Object<Metadata>): u64 acquires MarketConfig {
        let config = borrow_global<MarketConfig>(@panana);
        *config.default_challenge_costs.borrow_with_default(meta, &0)
    }

    /// Get the default market creation costs depending on the asset
    #[view]
    public fun market_creation_costs(meta: Object<Metadata>): u64 acquires MarketConfig {
        let config = borrow_global<MarketConfig>(@panana);
        *config.market_creation_cost.borrow_with_default(meta, &0)
    }

    /// Get the address that the market fees are transferred to
    #[view]
    public fun market_fee_address(): address acquires MarketConfig {
        let config = borrow_global<MarketConfig>(@panana);
        config.market_fee_address
    }

    /// Returns the default challenge duration for all markets.
    #[view]
    public fun default_challenge_duration_sec(): u64 acquires MarketConfig {
        let config = borrow_global<MarketConfig>(@panana);
        config.default_challenge_duration_sec
    }

    /// Returns true if the global contract has been frozen.
    #[view]
    public fun is_frozen(): bool acquires MarketConfig {
        let config = borrow_global<MarketConfig>(@panana);
        config.is_frozen
    }

    /// Get current resolver
    #[view]
    public fun resolver(): address acquires MarketConfig {
        borrow_global<MarketConfig>(@panana).resolver
    }

    /// Get resolution oracle address
    #[view]
    public fun resolution_oracle(): address acquires MarketConfig {
        borrow_global<MarketConfig>(@panana).resolution_oracle
    }

    /// Read current admin
    #[view]
    public fun admin(): address acquires MarketConfig {
        borrow_global<MarketConfig>(@panana).admin
    }

    #[test_only]
    public fun init_test(account: &signer) {
        init_module(account);
    }
}