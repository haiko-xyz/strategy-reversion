use starknet::ContractAddress;

#[starknet::interface]
pub trait IVaultToken<TContractState> {
    fn strategy(self: @TContractState) -> ContractAddress;
    fn mint(ref self: TContractState, account: ContractAddress, amount: u256);
    fn burn(ref self: TContractState, account: ContractAddress, amount: u256);
}
