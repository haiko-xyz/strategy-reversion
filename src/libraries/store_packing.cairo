// Core lib imports.
use starknet::storage_access::StorePacking;

// Local imports.
use haiko_strategy_reversion::types::{Trend, StrategyState, PositionRange, PackedStrategyState};

////////////////////////////////
// CONSTANTS
////////////////////////////////

const TWO_POW_32: u256 = 0x100000000;
const TWO_POW_64: u256 = 0x10000000000000000;
const TWO_POW_96: u256 = 0x1000000000000000000000000;
const TWO_POW_128: u256 = 0x100000000000000000000000000000000;
const TWO_POW_160: u256 = 0x10000000000000000000000000000000000000000;
const TWO_POW_162: u256 = 0x40000000000000000000000000000000000000000;
const TWO_POW_164: u256 = 0x100000000000000000000000000000000000000000;
const TWO_POW_165: u256 = 0x200000000000000000000000000000000000000000;

const MASK_1: u256 = 0x1;
const MASK_2: u256 = 0x3;
const MASK_32: u256 = 0xffffffff;

////////////////////////////////
// STORE PACKING
////////////////////////////////

pub(crate) impl StrategyStateStorePacking of StorePacking<StrategyState, PackedStrategyState> {
    fn pack(value: StrategyState) -> PackedStrategyState {
        let slab0: felt252 = value.base_reserves.try_into().expect('BaseResOF');
        let slab1: felt252 = value.quote_reserves.try_into().expect('QuoteResOF');
        let mut slab2: u256 = value.bid.lower_limit.into();
        slab2 += value.bid.upper_limit.into() * TWO_POW_32;
        slab2 += value.ask.lower_limit.into() * TWO_POW_64;
        slab2 += value.ask.upper_limit.into() * TWO_POW_96;
        slab2 += value.range.into() * TWO_POW_128;
        slab2 += trend_to_u256(value.trend) * TWO_POW_160;
        slab2 += trend_to_u256(value.queued_trend) * TWO_POW_162;
        slab2 += bool_to_u256(value.is_initialised) * TWO_POW_164;
        slab2 += bool_to_u256(value.is_paused) * TWO_POW_165;

        PackedStrategyState { slab0, slab1, slab2: slab2.try_into().expect('Slab2OF') }
    }

    fn unpack(value: PackedStrategyState) -> StrategyState {
        let base_reserves: u256 = value.slab0.into();
        let quote_reserves: u256 = value.slab1.into();
        let bid_lower: u32 = (value.slab2.into() & MASK_32).try_into().unwrap();
        let bid_upper: u32 = ((value.slab2.into() / TWO_POW_32.into()) & MASK_32)
            .try_into()
            .unwrap();
        let ask_lower: u32 = ((value.slab2.into() / TWO_POW_64.into()) & MASK_32)
            .try_into()
            .unwrap();
        let ask_upper: u32 = ((value.slab2.into() / TWO_POW_96.into()) & MASK_32)
            .try_into()
            .unwrap();
        let range: u32 = ((value.slab2.into() / TWO_POW_128.into()) & MASK_32).try_into().unwrap();
        let trend: Trend = u256_to_trend((value.slab2.into() / TWO_POW_160.into()) & MASK_2);
        let queued_trend: Trend = u256_to_trend((value.slab2.into() / TWO_POW_162.into()) & MASK_2);
        let is_initialised: bool = (value.slab2.into() / TWO_POW_164.into()) & MASK_1 == 1;
        let is_paused: bool = (value.slab2.into() / TWO_POW_165.into()) & MASK_1 == 1;

        let bid = PositionRange { lower_limit: bid_lower, upper_limit: bid_upper, };
        let ask = PositionRange { lower_limit: ask_lower, upper_limit: ask_upper, };
        StrategyState {
            base_reserves,
            quote_reserves,
            bid,
            ask,
            range,
            trend,
            queued_trend,
            is_initialised,
            is_paused,
        }
    }
}

////////////////////////////////
// INTERNAL HELPERS
////////////////////////////////

fn bool_to_u256(value: bool) -> u256 {
    if value {
        1
    } else {
        0
    }
}

fn trend_to_u256(trend: Trend) -> u256 {
    match trend {
        Trend::Range => 0,
        Trend::Up => 1,
        Trend::Down => 2,
    }
}

fn u256_to_trend(value: u256) -> Trend {
    if value == 1 {
        return Trend::Up(());
    }
    if value == 2 {
        return Trend::Down(());
    }
    Trend::Range(())
}
