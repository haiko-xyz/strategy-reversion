// Core lib imports.
use starknet::syscalls::deploy_syscall;
use starknet::contract_address::contract_address_const;

// Local imports.
use haiko_strategy_reversion::contracts::mocks::store_packing_contract::{
    StorePackingContract, IStorePackingContractDispatcher, IStorePackingContractDispatcherTrait
};
use haiko_strategy_reversion::types::{Trend, StrategyState, PositionRange};

// External imports.
use snforge_std::{
    declare, ContractClass, ContractClassTrait, start_prank, stop_prank, CheatTarget, spy_events,
    SpyOn, EventSpy, EventAssertions, EventFetcher, start_warp
};

////////////////////////////////
// SETUP
////////////////////////////////

fn before() -> IStorePackingContractDispatcher {
    // Deploy store packing contract.
    let class = declare("StorePackingContract");
    let contract_address = class.deploy(@array![]).unwrap();
    IStorePackingContractDispatcher { contract_address }
}

////////////////////////////////
// TESTS
////////////////////////////////

#[test]
fn test_store_packing_strategy_state() {
    let store_packing_contract = before();

    let strategy_params = StrategyState {
        base_reserves: 1238128312093,
        quote_reserves: 9123192389312712,
        bid: PositionRange { lower_limit: 1234, upper_limit: 2345 },
        ask: PositionRange { lower_limit: 7777, upper_limit: 8888 },
        range: 5000,
        trend: Trend::Up,
        queued_trend: Trend::Range,
        is_initialised: true,
        is_paused: false,
    };

    store_packing_contract.set_strategy_state(1, strategy_params);
    let unpacked = store_packing_contract.get_strategy_state(1);

    assert(unpacked.base_reserves == strategy_params.base_reserves, 'Params: base reserves');
    assert(unpacked.quote_reserves == strategy_params.quote_reserves, 'Params: quote reserves');
    assert(unpacked.bid.lower_limit == strategy_params.bid.lower_limit, 'Params: bid lower');
    assert(unpacked.bid.upper_limit == strategy_params.bid.upper_limit, 'Params: bid upper');
    assert(unpacked.ask.lower_limit == strategy_params.ask.lower_limit, 'Params: ask lower');
    assert(unpacked.ask.upper_limit == strategy_params.ask.upper_limit, 'Params: ask upper');
    assert(unpacked.range == strategy_params.range, 'Params: range');
    assert(unpacked.trend == strategy_params.trend, 'Params: trend');
    assert(unpacked.queued_trend == strategy_params.queued_trend, 'Params: queued trend');
    assert(unpacked.is_initialised == strategy_params.is_initialised, 'Params: is initialised');
    assert(unpacked.is_paused == strategy_params.is_paused, 'Params: is paused');
}
