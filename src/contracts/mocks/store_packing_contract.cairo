use haiko_strategy_reversion::types::StrategyState;

#[starknet::interface]
pub trait IStorePackingContract<TContractState> {
    fn get_strategy_state(self: @TContractState, market_id: felt252) -> StrategyState;

    fn set_strategy_state(
        ref self: TContractState, market_id: felt252, strategy_state: StrategyState
    );
}

#[starknet::contract]
pub mod StorePackingContract {
    use super::IStorePackingContract;
    use haiko_strategy_reversion::types::StrategyState;
    use haiko_strategy_reversion::libraries::store_packing::StrategyStateStorePacking;

    ////////////////////////////////
    // STORAGE
    ////////////////////////////////

    #[storage]
    struct Storage {
        strategy_state: LegacyMap::<felt252, StrategyState>,
    }

    #[constructor]
    fn constructor(ref self: ContractState,) {}

    #[abi(embed_v0)]
    impl StorePackingContract of IStorePackingContract<ContractState> {
        ////////////////////////////////
        // VIEW FUNCTIONS
        ////////////////////////////////

        fn get_strategy_state(self: @ContractState, market_id: felt252) -> StrategyState {
            self.strategy_state.read(market_id)
        }

        ////////////////////////////////
        // EXTERNAL FUNCTIONS
        ////////////////////////////////

        fn set_strategy_state(
            ref self: ContractState, market_id: felt252, strategy_state: StrategyState
        ) {
            self.strategy_state.write(market_id, strategy_state);
        }
    }
}
