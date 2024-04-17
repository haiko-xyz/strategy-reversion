// Core lib imports.
use starknet::ContractAddress;
use core::fmt::{Display, Formatter, Error};

// Haiko imports.
use haiko_lib::types::core::PositionInfo;

////////////////////////////////
// TYPES
////////////////////////////////

// Classification of price trend.
//
// * `Range` - price is ranging
// * `Up` - price is trending up
// * `Down` - price is trending down
#[derive(Drop, Copy, Serde, Default, PartialEq)]
pub enum Trend {
    #[default]
    Range,
    Up,
    Down,
}

impl TrendDisplay of Display<Trend> {
    fn fmt(self: @Trend, ref f: Formatter) -> Result<(), Error> {
        let trend: ByteArray = match self {
            Trend::Range => "Range",
            Trend::Up => "Up",
            Trend::Down => "Down",
        };
        return write!(f, "{trend}");
    }
}

// Strategy position.
//
// * `lower_limit` - lower limit of position
// * `upper_limit` - upper limit of position
#[derive(Drop, Copy, Serde, Default, PartialEq)]
pub struct PositionRange {
    pub lower_limit: u32,
    pub upper_limit: u32,
}

// Strategy state.
//
// * `base_reserves` - base reserves
// * `quote_reserves` - quote reserves
// * `bid` - placed bid, or lower_limit = upper_limit = 0 if none placed
// * `ask` - placed ask, or lower_limit = upper_limit = 0 if none placed
// * `range` - range
// * `trend` - trend
// * `queued_trend` - queued trend (to be applied on next update)
// * `is_initialised` - whether strategy is initialised
// * `is_paused` - whether strategy is paused
#[derive(Drop, Copy, Serde, Default)]
pub struct StrategyState {
    pub base_reserves: u256,
    pub quote_reserves: u256,
    pub bid: PositionRange,
    pub ask: PositionRange,
    pub range: u32,
    pub trend: Trend,
    pub queued_trend: Trend,
    pub is_initialised: bool,
    pub is_paused: bool,
}

////////////////////////////////
// PACKED TYPES
////////////////////////////////

// Packed strategy parameters.
//
// * `slot0` - base reserves (coerced to felt252)
// * `slot1` - quote reserves (coerced to felt252)
// * `slot2` - `bid_lower` (32) + `bid_upper` (32) + `ask_lower` (32) + `ask_upper` (32) + `range` (32) + 
//             `trend` (2) + `queued_trend` (2) + `is_initialised` (1) + `is_paused` (1)
// Where: 
// * `trend` and `queued_trend` are encoded as: `0` (Range), `1` (Up), `2` (Down) 
#[derive(starknet::Store)]
pub struct PackedStrategyState {
    pub slab0: felt252,
    pub slab1: felt252,
    pub slab2: felt252
}
