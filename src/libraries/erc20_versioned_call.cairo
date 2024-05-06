// Core lib imports.
use starknet::ContractAddress;
use starknet::syscalls::{replace_class_syscall, deploy_syscall, call_contract_syscall};

// Local imports.
use haiko_strategy_reversion::interfaces::IERC20Metadata::{
    IERC20MetadataFelt252Dispatcher, IERC20MetadataFelt252DispatcherTrait
};

// Fetch the symbol of an ERC20 token.
// Older ERC20 tokens use `felt252` symbols, whereas newer ones use `ByteArray`.
// This function examines the length of the returned array from `call_contract_syscall`
// to handle both cases.
// 
// # Arguments
// * `contract_address` - address of ERC20 token
// * `selector` - erc20 entry point selector
pub fn get_symbol(contract_address: ContractAddress) -> ByteArray {
    let result = call_contract_syscall(
        contract_address, selector!("symbol"), ArrayTrait::<felt252>::new().span()
    )
        .unwrap();
    let length = result.len();
    let mut name: ByteArray = "";
    // Switch between cases based on the length of the result array.
    // If the length is 1, then the symbol is a `felt252`.
    // If the length is greater than 1, then the symbol is a `ByteArray`.
    if length == 1 {
        let mut byte_array: ByteArray = "";
        byte_array.append_word(*result.at(0), 31);
        let mut i = 0;
        loop {
            if i == byte_array.len() {
                break;
            }
            let byte = byte_array.at(i).unwrap();
            if byte != 0 {
                name.append_byte(byte);
            }
            i += 1;
        };
    } else {
        let pending_word_len: u32 = (*result.at(length - 1)).try_into().unwrap();
        let mut i = 1;
        loop {
            if i == length - 1 {
                break;
            }
            let word = *result.at(i);
            let word_len = if i == length - 2 {
                pending_word_len
            } else {
                31
            };
            name.append_word(word, word_len);
            i += 1;
        };
    }
    name
}
