module panana::vaa_parser {
    use std::vector;
    use aptos_framework::timestamp;
    use pyth::merkle;
    use pyth::keccak160;
    use pyth::price_feed;
    use pyth::price_info;
    use pyth::price_identifier;
    use wormhole::cursor;
    use wormhole::u16;
    use pyth::data_source;
    use pyth::state;
    use wormhole::vaa;
    use pyth::deserialize;
    use pyth::price_info::PriceInfo;
    use wormhole::cursor::Cursor;

    const PYTHNET_ACCUMULATOR_UPDATE_MAGIC: u64 = 1347305813;
    const ACCUMULATOR_UPDATE_WORMHOLE_VERIFICATION_MAGIC: u64 = 1096111958;

    const E_INVALID_ACCUMULATOR_PAYLOAD: u64 = 0;
    const E_INVALID_ACCUMULATOR_MESSAGE: u64 = 1;
    const E_PYTHNET_MAGIC_NUMBER_MISMATCH: u64 = 2;
    const E_INVALID_DATA_SOURCE: u64 = 3;
    const E_INVALID_WORMHOLE_MESSAGE: u64 = 4;
    const E_INVALID_PROOF: u64 = 5;

    /// Public function to parse and validate an incoming vaa message
    public fun parse_and_verify_accumulator_message(vaa: vector<u8>): vector<PriceInfo> {
        let cur = cursor::init(vaa);
        let header: u64 = deserialize::deserialize_u32(&mut cur);
        assert!(header == PYTHNET_ACCUMULATOR_UPDATE_MAGIC, E_PYTHNET_MAGIC_NUMBER_MISMATCH);
        let result = parse_and_verify_accumulator_cursor(&mut cur);
        cursor::destroy_empty(cur);
        result
    }
    
    /// Given a cursor at the beginning of an accumulator message, verifies the validity of the message and the
    /// embedded VAA, parses and verifies the price updates and returns an array of PriceInfo representing the updates
    fun parse_and_verify_accumulator_cursor(cursor: &mut Cursor<u8>): vector<PriceInfo> {
        let major = deserialize::deserialize_u8(cursor);
        assert!(major == 1, E_INVALID_ACCUMULATOR_PAYLOAD);
        let _minor = deserialize::deserialize_u8(cursor);

        let trailing_size = deserialize::deserialize_u8(cursor);
        deserialize::deserialize_vector(cursor, (trailing_size as u64));

        let proof_type = deserialize::deserialize_u8(cursor);
        assert!(proof_type == 0, E_INVALID_ACCUMULATOR_PAYLOAD);

        let vaa_size = deserialize::deserialize_u16(cursor);
        let vaa = deserialize::deserialize_vector(cursor, vaa_size);
        let msg_vaa = vaa::parse_and_verify(vaa);
        assert!(
            state::is_valid_data_source(
                data_source::new(
                    u16::to_u64(vaa::get_emitter_chain(&msg_vaa)),
                    vaa::get_emitter_address(&msg_vaa))),
            E_INVALID_DATA_SOURCE);
        let merkle_root_hash = parse_accumulator_merkle_root_from_vaa_payload(vaa::get_payload(&msg_vaa));
        vaa::destroy(msg_vaa);
        parse_and_verify_accumulator_updates(cursor, &merkle_root_hash)
    }

    /// Given a single accumulator price update message, asserts that it is a PriceFeedMessage,
    /// parses the info and returns a PriceInfo representing the encoded information
    fun parse_accumulator_update_message(message: vector<u8>): PriceInfo {
        let message_cur = cursor::init(message);
        let message_type = deserialize::deserialize_u8(&mut message_cur);

        assert!(message_type == 0, E_INVALID_ACCUMULATOR_MESSAGE); // PriceFeedMessage variant
        let price_identifier = price_identifier::from_byte_vec(deserialize::deserialize_vector(&mut message_cur, 32));
        let price = deserialize::deserialize_i64(&mut message_cur);
        let conf = deserialize::deserialize_u64(&mut message_cur);
        let expo = deserialize::deserialize_i32(&mut message_cur);
        let publish_time = deserialize::deserialize_u64(&mut message_cur);
        let _prev_publish_time = deserialize::deserialize_i64(&mut message_cur);
        let ema_price = deserialize::deserialize_i64(&mut message_cur);
        let ema_conf = deserialize::deserialize_u64(&mut message_cur);
        let price_info = price_info::new(
            timestamp::now_seconds(), // not used anywhere kept for backward compatibility
            timestamp::now_seconds(),
            price_feed::new(
                price_identifier,
                pyth::price::new(price, conf, expo, publish_time),
                pyth::price::new(ema_price, ema_conf, expo, publish_time),
            )
        );
        cursor::rest(message_cur);
        price_info
    }

    /// Given a cursor at the beginning of accumulator price updates array data and a merkle_root hash,
    /// parses the price updates and proofs, verifies the proofs against the merkle_root and
    /// returns an array of PriceInfo representing the updates
    fun parse_and_verify_accumulator_updates(
        cursor: &mut Cursor<u8>,
        merkle_root: &keccak160::Hash
    ): vector<PriceInfo> {
        let update_size = deserialize::deserialize_u8(cursor);
        let updates: vector<PriceInfo> = vector[];
        while (update_size > 0) {
            let message_size = deserialize::deserialize_u16(cursor);
            let message = deserialize::deserialize_vector(cursor, message_size);
            let update = parse_accumulator_update_message(message);
            vector::push_back(&mut updates, update);
            let path_size = deserialize::deserialize_u8(cursor);
            let merkle_path: vector<keccak160::Hash> = vector[];
            while (path_size > 0) {
                let hash = deserialize::deserialize_vector(cursor, keccak160::get_hash_length());
                vector::push_back(&mut merkle_path, keccak160::new(hash));
                path_size = path_size - 1;
            };
            assert!(merkle::check(&merkle_path, merkle_root, message), E_INVALID_PROOF);
            update_size = update_size - 1;
        };
        updates
    }

    /// Given the payload of a VAA related to accumulator messages, asserts the verification variant is merkle and
    /// extracts the merkle root digest
    fun parse_accumulator_merkle_root_from_vaa_payload(message: vector<u8>): keccak160::Hash {
        let msg_payload_cursor = cursor::init(message);
        let payload_type = deserialize::deserialize_u32(&mut msg_payload_cursor);
        assert!(payload_type == ACCUMULATOR_UPDATE_WORMHOLE_VERIFICATION_MAGIC, E_INVALID_WORMHOLE_MESSAGE);
        let wh_message_payload_type = deserialize::deserialize_u8(&mut msg_payload_cursor);
        assert!(wh_message_payload_type == 0, E_INVALID_WORMHOLE_MESSAGE); // Merkle variant
        let _merkle_root_slot = deserialize::deserialize_u64(&mut msg_payload_cursor);
        let _merkle_root_ring_size = deserialize::deserialize_u32(&mut msg_payload_cursor);
        let merkle_root_hash = deserialize::deserialize_vector(&mut msg_payload_cursor, 20);
        cursor::rest(msg_payload_cursor);
        keccak160::new(merkle_root_hash)
    }    
}