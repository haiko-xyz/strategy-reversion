#[starknet::interface]
pub trait IERC20ByteArray<TContractState> {
    fn name(self: @TContractState) -> ByteArray;
    fn symbol(self: @TContractState) -> ByteArray;
}

#[starknet::contract]
pub mod ERC20ByteArray {
    use super::IERC20ByteArray;
    use starknet::ContractAddress;

    #[storage]
    struct Storage {
        name: ByteArray,
        symbol: ByteArray,
    }

    #[constructor]
    fn constructor(ref self: ContractState, name: ByteArray, symbol: ByteArray) {
        self.name.write(name);
        self.symbol.write(symbol);
    }

    #[abi(embed_v0)]
    impl ERC20ByteArray of IERC20ByteArray<ContractState> {
        fn name(self: @ContractState) -> ByteArray {
            self.name.read()
        }

        fn symbol(self: @ContractState) -> ByteArray {
            self.symbol.read()
        }
    }
}
