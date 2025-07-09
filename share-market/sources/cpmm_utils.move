module panana::cpmm_utils {
    use std::bcs;
    use std::option;
    use std::option::Option;
    use std::vector;
    use aptos_std::comparator;
    use aptos_std::math128;
    use aptos_framework::fungible_asset;
    use aptos_framework::fungible_asset::{Metadata, FungibleAsset};
    use aptos_framework::object::{Object, object_address};

    /// A list of all hex symbols
    const HEX_SYMBOLS: vector<u8> = b"0123456789abcdef";

    /// Creates an identifier for a token pair
    /// The idenfifier consists of the addresses of both tokens cast to bytes and appended
    /// `token_a_metadata` token a to create the identifier for
    /// `token_b_metadata` token b to create the identifier for
    public fun ordered_asset_pair_identifier(
        token_a_metadata: Object<Metadata>,
        token_b_metadata: Object<Metadata>,
    ): vector<u8> {
        // Sort the tokens so the order of passed tokens does not matter
        // Token A-B and B-A produce the same ID
        let (first_token_metadata, second_token_metadata) = order_token_metadata(token_a_metadata, token_b_metadata);
        let identifier = vector::empty<u8>();
        identifier.append(bcs::to_bytes(&object_address(&first_token_metadata)));
        identifier.append(bcs::to_bytes(&object_address(&second_token_metadata)));

        identifier
    }

    /// Order the provided metadata objects.
    public fun order_token_metadata(
        token_a_metadata: Object<Metadata>,
        token_b_metadata: Object<Metadata>,
    ): (Object<Metadata>, Object<Metadata>) {
        if ((comparator::compare(&token_a_metadata, &token_b_metadata)).is_smaller_than()) {
            return (token_a_metadata, token_b_metadata)
        };
        return (token_b_metadata, token_a_metadata)
    }

    /// Order tokens based on their metadata object address.
    public fun order_tokens(
        token_a: FungibleAsset,
        token_b: FungibleAsset,
    ): (FungibleAsset, FungibleAsset) {
        let token_a_metadata = fungible_asset::metadata_from_asset(&token_a);
        let token_b_metadata = fungible_asset::metadata_from_asset(&token_b);
        if ((comparator::compare(&token_a_metadata, &token_b_metadata)).is_smaller_than()) {
            return (token_a, token_b)
        };
        return (token_b, token_a)
    }

    /// Calculate the absolute diff of the two values (= |a - b|)
    public inline fun abs_diff(a: u64, b: u64): u64 {
        if (a > b) a - b else b - a
    }

    // solve for n: (x-n)(y-n)=k
    // calculation: ((x+y)+sqrt((x-y)^2+4k))/2
    /// Solve a quadratic equation and return the two possible results
    public fun solve_quadratic_equation(x: u64, y: u64, k: u128): (u64, Option<u64>) {
        // Calculate discriminant: x^2 - 2xy + y^2 + 4k
        let diff = (abs_diff(x, y) as u128);
        let discriminant = diff * diff + 4 * k;

        // Calculate square root of discriminant
        let sqrt_discriminant = (math128::sqrt(discriminant) as u64);
        // Calculate the two possible solutions for n
        // sqrt_discriminant has been floored; if we add it, the result is smaller or equal than the actual result.
        let n1 = ((x + y) + sqrt_discriminant) / 2;
        // sqrt_discriminant has been floored; if we subtract it, the remainder may cause an overflow. Thus, we subtract 1.
        let n2 = if (x+y >= sqrt_discriminant + 1) option::some(((x + y) - (sqrt_discriminant + 1)) / 2) else option::none();
        (n1, n2)
    }

    /// Converts a `u64` to its hexadecimal representation.
    public fun to_hex(value: u64): vector<u8> {
        if (value == 0) {
            return b"0x00";
        };
        let temp = value;
        let length = 0;
        while (temp != 0) {
            length = length + 1;
            temp = temp >> 8;
        };
        to_hex_string_fixed_length(value, length)
    }

    /// Converts a `u64` to its `string::String` hexadecimal representation with fixed length (in whole bytes).
    /// so the returned String is `2 * length + 2`(with '0x') in size
    public fun to_hex_string_fixed_length(value: u64, length: u64): vector<u8> {
        let buffer = vector::empty<u8>();

        let i: u64 = 0;
        while (i < length * 2) {
            buffer.push_back(HEX_SYMBOLS[(value & 0xf)]);
            value = value >> 4;
            i = i + 1;
        };
        assert!(value == 0, 1);
        buffer.append(b"x0");
        buffer.reverse();
        buffer
    }

    #[test]
    public fun test_solve_quadratic_equation() {
        let (n1, n2) = solve_quadratic_equation(10, 20, 50);
        assert!(n1 == 23);
        assert!(*n2.borrow() == 6);

        let (n1, n2) = solve_quadratic_equation(2, 10, 50);
        assert!(n1 == 14);
        assert!(n2.is_none());
    }
}
