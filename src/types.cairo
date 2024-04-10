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
// TODO: implement storepacking
#[derive(Drop, Copy, Serde, Default, PartialEq, starknet::Store)]
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
        return writeln!(f, "{trend}");
    }
}

// Strategy position.
//
// * `lower_limit` - lower limit of position
// * `upper_limit` - upper limit of position
// TODO: implement storepacking
#[derive(Drop, Copy, Serde, Default, PartialEq, starknet::Store)]
pub struct PositionRange {
    pub lower_limit: u32,
    pub upper_limit: u32,
}

// Strategy state.
//
// * `is_initialised` - whether strategy is initialised
// * `is_paused` - whether strategy is paused
// * `trend` - trend
// * `queued_trend` - queued trend (to be applied on next update)
// * `range` - range
// * `base_reserves` - base reserves
// * `quote_reserves` - quote reserves
// * `bid` - placed bid, or lower_limit = upper_limit = 0 if none placed
// * `ask` - placed ask, or lower_limit = upper_limit = 0 if none placed
// TODO: implement storepacking
#[derive(Drop, Copy, Serde, Default, starknet::Store)]
pub struct StrategyState {
    pub is_initialised: bool,
    pub is_paused: bool,
    pub trend: Trend,
    pub queued_trend: Trend,
    pub range: u32,
    pub base_reserves: u256,
    pub quote_reserves: u256,
    pub bid: PositionRange,
    pub ask: PositionRange,
}
