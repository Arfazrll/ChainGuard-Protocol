//! Decimal-string serde for 256-bit integers (lossless through JSON and ClickHouse).

pub mod dec_u256 {
    use alloy_primitives::U256;
    use serde::{Deserialize, Deserializer, Serializer, de::Error};

    pub fn serialize<S: Serializer>(v: &U256, s: S) -> Result<S::Ok, S::Error> {
        s.collect_str(v)
    }

    pub fn deserialize<'de, D: Deserializer<'de>>(d: D) -> Result<U256, D::Error> {
        let s = String::deserialize(d)?;
        s.parse::<U256>().map_err(D::Error::custom)
    }
}

pub mod dec_i256 {
    use alloy_primitives::I256;
    use serde::{Deserialize, Deserializer, Serializer, de::Error};

    pub fn serialize<S: Serializer>(v: &I256, s: S) -> Result<S::Ok, S::Error> {
        s.collect_str(v)
    }

    pub fn deserialize<'de, D: Deserializer<'de>>(d: D) -> Result<I256, D::Error> {
        let s = String::deserialize(d)?;
        s.parse::<I256>().map_err(D::Error::custom)
    }
}
