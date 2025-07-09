module panana::resource_utils {
    use std::option;
    use std::string::utf8;
    use aptos_framework::fungible_asset;
    use aptos_framework::fungible_asset::{Metadata, FungibleStore, MintRef, BurnRef, mint_ref_metadata };
    use aptos_framework::object;
    use aptos_framework::object::{ExtendRef, Object, DeleteRef, ConstructorRef,
        address_from_constructor_ref,
        generate_signer_for_extending,
        generate_extend_ref,
        create_named_object
    };
    use aptos_framework::primary_fungible_store;

    /// Helper to create a new token store and generate required references
    public inline fun create_token_store(owner: address, token: Object<Metadata>): (Object<FungibleStore>, ExtendRef, DeleteRef) {
        let constructor_ref = &object::create_object(owner);
        (fungible_asset::create_store(constructor_ref, token), object::generate_extend_ref(constructor_ref), object::generate_delete_ref(constructor_ref))
    }

    /// Helper to generate a new token.
    public inline fun create_token(extend_ref: &ExtendRef, asset_symbol: vector<u8>): (MintRef, BurnRef, Object<Metadata>) {
        let global_state_signer = object::generate_signer_for_extending(extend_ref);

        let constructor_ref = object::create_named_object(&global_state_signer, asset_symbol);

        let icon_uri = utf8(b"https://panana-predictions.xyz/tokens/");
        icon_uri.append_utf8(asset_symbol);

        // Create Yes and No tokens
        primary_fungible_store::create_primary_store_enabled_fungible_asset(
            &constructor_ref,
            option::none(),
            utf8(asset_symbol),
            utf8(asset_symbol),
            8,
            icon_uri,
            utf8(b"https://panana-predictions.xyz"),
        );

        let mint_ref = fungible_asset::generate_mint_ref(&constructor_ref);
        let burn_ref = fungible_asset::generate_burn_ref(&constructor_ref);
        let metadata = mint_ref_metadata(&mint_ref);

        (mint_ref, burn_ref, metadata)
    }

    /// Utility to create a named object for the provided signer and seed and get the required object references.
    public fun create_seed_object(
        creator: &signer,
        seed: vector<u8>
    ): (signer, ExtendRef, address){
        let pool_ctor: ConstructorRef = create_named_object(creator, seed);
        let extend_ref = generate_extend_ref(&pool_ctor);
        let signer = generate_signer_for_extending(&extend_ref);
        let address = address_from_constructor_ref(&pool_ctor);

        (signer, extend_ref, address)
    }
}