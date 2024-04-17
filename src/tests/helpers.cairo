// Core lib imports.
use starknet::syscalls::deploy_syscall;
use starknet::ContractAddress;
use starknet::class_hash::ClassHash;

// Local imports.
use haiko_strategy_reversion::interfaces::ITrendStrategy::ITrendStrategyDispatcher;

// External imports.
use snforge_std::{declare, ContractClassTrait};

pub fn deploy_trend_strategy(
    owner: ContractAddress, market_manager: ContractAddress, vault_token_class: ClassHash,
) -> ITrendStrategyDispatcher {
    let contract = declare("ReversionStrategy");
    let name: ByteArray = "Trend";
    let symbol: ByteArray = "TRND";
    let mut calldata: Array<felt252> = array![];
    owner.serialize(ref calldata);
    name.serialize(ref calldata);
    symbol.serialize(ref calldata);
    market_manager.serialize(ref calldata);
    vault_token_class.serialize(ref calldata);
    let contract_address = contract.deploy(@calldata).unwrap();
    ITrendStrategyDispatcher { contract_address }
}
