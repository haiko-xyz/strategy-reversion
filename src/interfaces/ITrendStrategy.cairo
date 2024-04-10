// Core lib imports.
use starknet::ContractAddress;
use starknet::class_hash::ClassHash;

// Local imports.
use haiko_strategy_trend::types::{StrategyState, Trend};

// Haiko imports.
use haiko_lib::types::core::{PositionInfo, SwapParams};


#[starknet::interface]
pub trait ITrendStrategy<TContractState> {
    // Contract owner
    fn owner(self: @TContractState) -> ContractAddress;

    // Queued contract owner, used for ownership transfers
    fn queued_owner(self: @TContractState) -> ContractAddress;

    // Set trend for a given market
    fn trend(self: @TContractState, market_id: felt252) -> Trend;

    // Strategy state
    fn strategy_state(self: @TContractState, market_id: felt252) -> StrategyState;

    // Whether strategy is paused for a given market
    fn is_paused(self: @TContractState, market_id: felt252) -> bool;

    // Base reserves of strategy
    fn base_reserves(self: @TContractState, market_id: felt252) -> u256;

    // Quote reserves of strategy
    fn quote_reserves(self: @TContractState, market_id: felt252) -> u256;

    // Withdraw fee rate for a given market
    fn withdraw_fee_rate(self: @TContractState, market_id: felt252) -> u16;

    // Accumulated withdraw fee balance for a given asset
    fn withdraw_fees(self: @TContractState, token: ContractAddress) -> u256;

    // Get total tokens held in strategy, whether in reserves or in positions.
    // 
    // # Arguments
    // * `market_id` - market id
    //
    // # Returns
    // * `base_amount` - total base tokens owned
    // * `quote_amount` - total quote tokens owned
    fn get_balances(self: @TContractState, market_id: felt252) -> (u256, u256);

    // Initialise strategy for market.
    // At the moment, only callable by contract owner to prevent unwanted claiming of strategies. 
    //
    // # Arguments
    // * `market_id` - market id
    // * `owner` - nominated owner for strategy
    // * `trend` - initial trend
    // * `range` - range parameter (width, in limits, of bid and ask liquidity positions)
    fn add_market(
        ref self: TContractState,
        market_id: felt252,
        owner: ContractAddress,
        trend: Trend,
        range: u32,
    ) -> ContractAddress;

    // Deposit initial liquidity to strategy and place positions.
    // Should be used whenever total deposits in a strategy are zero. This can happen both
    // when a strategy is first initialised, or subsequently whenever all deposits are withdrawn.
    // The deposited amounts will constitute the starting reserves of the strategy, so initial
    // base and quote deposits should be balanced in value to avoid portfolio skew.
    //
    // # Arguments
    // * `market_id` - market id
    // * `base_amount` - base asset to deposit
    // * `quote_amount` - quote asset to deposit
    //
    // # Returns
    // * `shares` - pool shares minted in the form of liquidity
    fn deposit_initial(
        ref self: TContractState, market_id: felt252, base_amount: u256, quote_amount: u256
    ) -> u256;

    // Deposit liquidity to strategy.
    //
    // # Arguments
    // * `market_id` - market id
    // * `base_amount` - base asset desired
    // * `quote_amount` - quote asset desired
    //
    // # Returns
    // * `base_amount` - base asset deposited
    // * `quote_amount` - quote asset deposited
    // * `shares` - pool shares minted
    fn deposit(
        ref self: TContractState, market_id: felt252, base_amount: u256, quote_amount: u256
    ) -> (u256, u256, u256);

    // Burn pool shares and withdraw funds from strategy.
    //
    // # Arguments
    // * `market_id` - market id
    // * `shares` - pool shares to burn
    //
    // # Returns
    // * `base_amount` - base asset withdrawn
    // * `quote_amount` - quote asset withdrawn
    fn withdraw(ref self: TContractState, market_id: felt252, shares: u256) -> (u256, u256);

    // Manually trigger contract to collect all outstanding positions and pause the contract.
    // Only callable by owner.
    fn collect_and_pause(ref self: TContractState, market_id: felt252);

    // Collect withdrawal fees.
    // Only callable by contract owner.
    //
    // # Arguments
    // * `receiver` - address to receive fees
    // * `token` - token to collect fees for
    // * `amount` - amount of fees requested
    fn collect_withdraw_fees(
        ref self: TContractState, receiver: ContractAddress, token: ContractAddress, amount: u256
    ) -> u256;

    // Change the parameters of the strategy.
    // Only callable by owner.
    //
    // # Params
    // * `market_id` - market id
    // * `trend` - trend parameter
    // * `range` - range parameter (width, in limits, of bid and ask liquidity positions)
    fn set_strategy_params(ref self: TContractState, market_id: felt252, trend: Trend, range: u32);

    // Set withdraw fee for a given market.
    // Only callable by contract owner.
    //
    // # Arguments
    // * `market_id` - market id
    // * `fee_rate` - fee rate
    fn set_withdraw_fee(ref self: TContractState, market_id: felt252, fee_rate: u16);

    // Request transfer ownership of the contract.
    // Part 1 of 2 step process to transfer ownership.
    //
    // # Arguments
    // * `new_owner` - New owner of the contract
    fn transfer_owner(ref self: TContractState, new_owner: ContractAddress);

    // Called by new owner to accept ownership of the contract.
    // Part 2 of 2 step process to transfer ownership.
    fn accept_owner(ref self: TContractState);

    // Pause strategy. 
    // Only callable by owner. 
    // 
    // # Arguments
    // * `market_id` - market id of strategy
    fn pause(ref self: TContractState, market_id: felt252);

    // Unpause strategy.
    // Only callable by owner.
    //
    // # Arguments
    // * `market_id` - market id of strategy
    fn unpause(ref self: TContractState, market_id: felt252);

    // Trigger update of positions.
    // Only callable by owner.
    //
    // # Arguments
    // * `market_id` - market id of strategy
    fn trigger_update_positions(ref self: TContractState, market_id: felt252);

    // Upgrade contract class.
    // Callable by owner only.
    //
    // # Arguments
    // * `new_class_hash` - new class hash of contract
    fn upgrade(ref self: TContractState, new_class_hash: ClassHash);
}
