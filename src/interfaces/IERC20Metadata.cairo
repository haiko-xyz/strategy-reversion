#[starknet::interface]
pub trait IERC20MetadataFelt252<TContractState> {
    fn name(self: @TContractState) -> felt252;
    fn symbol(self: @TContractState) -> felt252;
}

#[starknet::interface]
pub trait IERC20MetadataByteArray<TContractState> {
    fn name(self: @TContractState) -> ByteArray;
    fn symbol(self: @TContractState) -> ByteArray;
}
