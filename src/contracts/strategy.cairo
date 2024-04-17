#[starknet::contract]
pub mod ReversionStrategy {
    // Core lib imports.
    use core::integer::BoundedInt;
    use core::cmp::{min, max};
    use starknet::ContractAddress;
    use starknet::contract_address::contract_address_const;
    use starknet::{get_caller_address, get_contract_address, get_block_number, get_block_timestamp};
    use starknet::class_hash::ClassHash;
    use starknet::syscalls::{replace_class_syscall, deploy_syscall};

    // Local imports.
    use haiko_strategy_reversion::libraries::{trend_math, store_packing::StrategyStateStorePacking};
    use haiko_strategy_reversion::types::{Trend, StrategyState};
    use haiko_strategy_reversion::interfaces::ITrendStrategy::ITrendStrategy;
    use haiko_strategy_reversion::interfaces::IVaultToken::{
        IVaultTokenDispatcher, IVaultTokenDispatcherTrait
    };

    // Haiko imports.
    use haiko_lib::{id, math::{math, price_math, liquidity_math, fee_math}};
    use haiko_lib::interfaces::IMarketManager::{
        IMarketManagerDispatcher, IMarketManagerDispatcherTrait
    };
    use haiko_lib::interfaces::IStrategy::IStrategy;
    use haiko_lib::types::core::{PositionInfo, SwapParams};
    use haiko_lib::types::i128::I128Trait;
    use haiko_lib::constants::MAX_FEE_RATE;

    // External imports.
    use openzeppelin::token::erc20::interface::{ERC20ABIDispatcher, ERC20ABIDispatcherTrait};

    ////////////////////////////////
    // STORAGE
    ///////////////////////////////

    #[storage]
    struct Storage {
        // OWNABLE
        // contract owner
        owner: ContractAddress,
        // queued contract owner (for ownership transfers)
        queued_owner: ContractAddress,
        // IMMUTABLES
        // strategy name
        name: ByteArray,
        // strategy symbol (for short representation)
        symbol: ByteArray,
        // market manager
        market_manager: IMarketManagerDispatcher,
        // erc20 class hash
        vault_token_class: ClassHash,
        // STRATEGY
        // Indexed by market id
        strategy_state: LegacyMap::<felt252, StrategyState>,
        // Indexed by market_id
        strategy_token: LegacyMap::<felt252, ERC20ABIDispatcher>,
        // Indexed by market_id
        withdraw_fee_rate: LegacyMap::<felt252, u16>,
        // Indexed by asset
        withdraw_fees: LegacyMap::<ContractAddress, u256>,
    }

    ////////////////////////////////
    // EVENTS
    ///////////////////////////////

    #[event]
    #[derive(Drop, starknet::Event)]
    pub(crate) enum Event {
        AddMarket: AddMarket,
        Deposit: Deposit,
        Withdraw: Withdraw,
        UpdatePositions: UpdatePositions,
        SetStrategyParams: SetStrategyParams,
        CollectWithdrawFee: CollectWithdrawFee,
        SetWithdrawFee: SetWithdrawFee,
        WithdrawFeeEarned: WithdrawFeeEarned,
        ChangeOwner: ChangeOwner,
        Pause: Pause,
        Unpause: Unpause,
        Upgraded: Upgraded,
    }

    #[derive(Drop, starknet::Event)]
    pub(crate) struct AddMarket {
        #[key]
        pub market_id: felt252,
        pub token: ContractAddress
    }

    #[derive(Drop, starknet::Event)]
    pub(crate) struct Deposit {
        #[key]
        pub caller: ContractAddress,
        #[key]
        pub market_id: felt252,
        pub base_amount: u256,
        pub quote_amount: u256,
        pub shares: u256,
    }

    #[derive(Drop, starknet::Event)]
    pub(crate) struct Withdraw {
        #[key]
        pub caller: ContractAddress,
        #[key]
        pub market_id: felt252,
        pub base_amount: u256,
        pub quote_amount: u256,
        pub shares: u256,
    }

    #[derive(Drop, starknet::Event)]
    pub(crate) struct UpdatePositions {
        #[key]
        pub market_id: felt252,
        pub bid_lower_limit: u32,
        pub bid_upper_limit: u32,
        pub bid_liquidity: u128,
        pub ask_lower_limit: u32,
        pub ask_upper_limit: u32,
        pub ask_liquidity: u128,
    }

    #[derive(Drop, starknet::Event)]
    pub(crate) struct SetStrategyParams {
        #[key]
        pub market_id: felt252,
        pub trend: Trend,
        pub range: u32,
    }

    #[derive(Drop, starknet::Event)]
    pub(crate) struct SetWithdrawFee {
        #[key]
        pub market_id: felt252,
        pub fee_rate: u16,
    }

    #[derive(Drop, starknet::Event)]
    pub(crate) struct WithdrawFeeEarned {
        #[key]
        pub market_id: felt252,
        #[key]
        pub token: ContractAddress,
        pub amount: u256,
    }

    #[derive(Drop, starknet::Event)]
    pub(crate) struct CollectWithdrawFee {
        #[key]
        pub receiver: ContractAddress,
        #[key]
        pub token: ContractAddress,
        pub amount: u256,
    }

    #[derive(Drop, starknet::Event)]
    pub(crate) struct ChangeOwner {
        pub old: ContractAddress,
        pub new: ContractAddress
    }

    #[derive(Drop, starknet::Event)]
    pub(crate) struct Pause {
        #[key]
        pub market_id: felt252,
    }

    #[derive(Drop, starknet::Event)]
    pub(crate) struct Unpause {
        #[key]
        pub market_id: felt252,
    }

    #[derive(Drop, starknet::Event)]
    pub(crate) struct Upgraded {
        pub class_hash: ClassHash,
    }

    ////////////////////////////////
    // CONSTRUCTOR
    ////////////////////////////////
    #[constructor]
    fn constructor(
        ref self: ContractState,
        owner: ContractAddress,
        name: ByteArray,
        symbol: ByteArray,
        market_manager: ContractAddress,
        vault_token_class: ClassHash,
    ) {
        self.owner.write(owner);
        self.name.write(name);
        self.symbol.write(symbol);
        let manager_dispatcher = IMarketManagerDispatcher { contract_address: market_manager };
        self.market_manager.write(manager_dispatcher);
        self.vault_token_class.write(vault_token_class);
    }

    ////////////////////////////////
    // FUNCTIONS
    ////////////////////////////////

    #[generate_trait]
    impl ModifierImpl of ModifierTrait {
        fn assert_owner(self: @ContractState) {
            assert(self.owner.read() == get_caller_address(), 'OnlyOwner');
        }
    }

    #[abi(embed_v0)]
    impl Strategy of IStrategy<ContractState> {
        // Get market manager contract address.
        fn market_manager(self: @ContractState) -> ContractAddress {
            self.market_manager.read().contract_address
        }

        // Get strategy name.
        fn name(self: @ContractState) -> ByteArray {
            self.name.read()
        }

        // Get strategy symbol.
        fn symbol(self: @ContractState) -> ByteArray {
            self.symbol.read()
        }

        // Get list of positions currently placed by strategy.
        //
        // # Returns
        // * `positions` - list of positions
        fn placed_positions(self: @ContractState, market_id: felt252) -> Span<PositionInfo> {
            // Read state.
            let market_manager = self.market_manager.read();
            let state = self.strategy_state.read(market_id);
            let contract: felt252 = get_contract_address().into();
            let bid_pos = market_manager
                .position(market_id, contract, state.bid.lower_limit, state.bid.upper_limit);
            let ask_pos = market_manager
                .position(market_id, contract, state.ask.lower_limit, state.ask.upper_limit);

            // Construct position info.
            let bid = PositionInfo {
                lower_limit: state.bid.lower_limit,
                upper_limit: state.bid.upper_limit,
                liquidity: bid_pos.liquidity
            };
            let ask = PositionInfo {
                lower_limit: state.ask.lower_limit,
                upper_limit: state.ask.upper_limit,
                liquidity: ask_pos.liquidity
            };

            // Return positions.
            array![bid, ask].span()
        }

        // Get list of positions queued to be placed by strategy on next `swap` update. If no updates
        // are queued, the returned list will match the list returned by `placed_positions`. Note that
        // the list of queued positions can differ depending on the incoming swap. 
        // 
        // # Returns
        // * `positions` - list of positions
        fn queued_positions(
            self: @ContractState, market_id: felt252, swap_params: Option<SwapParams>
        ) -> Span<PositionInfo> {
            // Read state.
            let market_manager = self.market_manager.read();
            let market_info = market_manager.market_info(market_id);
            let market_state = market_manager.market_state(market_id);
            let state = self.strategy_state.read(market_id);

            // Handle non-existent market and paused or uninitialised strategy.
            if market_info.width == 0 || state.is_paused || !state.is_initialised {
                return array![Default::default(), Default::default()].span();
            }

            // Extract params.
            let bid_lower = state.bid.lower_limit;
            let bid_upper = state.bid.upper_limit;
            let ask_lower = state.ask.lower_limit;
            let ask_upper = state.ask.upper_limit;
            let curr_limit = market_state.curr_limit;

            // We update positions if:
            // 1. Strategy params have changed, either:
            //    a. Trend
            //    b. Range
            // 2. The market is ranging, and:
            //    a. User is selling while price is inside our bid position
            //    b. User is buying while price is inside our ask position
            // 3. The market is moving in line with the trend:
            //    a. Price is above ask lower and user is buying, in an uptrend -> rebalance ask
            //    b. Price is below bid upper and use is selling, in a downtrend -> rebalance bid
            // Alternatively, if swap_params are not provided, we always update positions.
            let cond_1b_bid = bid_upper == bid_lower || (bid_upper - bid_lower) != state.range;
            let cond_1b_ask = ask_upper == ask_lower || (ask_upper - ask_lower) != state.range;
            let rebalance = if swap_params.is_none()
                || state.queued_trend != state.trend
                || cond_1b_bid
                || cond_1b_ask {
                true
            } else {
                let is_buy = swap_params.unwrap().is_buy;
                match state.trend {
                    Trend::Range => !is_buy
                        && curr_limit < bid_upper || is_buy
                        && curr_limit >= ask_lower,
                    Trend::Up => is_buy && curr_limit >= ask_lower,
                    Trend::Down => !is_buy && curr_limit < bid_upper,
                }
            };
            // println!("update_bid: {}, update_ask: {}", update_bid, update_ask);

            // Fetch amounts in existing position.
            let contract: felt252 = get_contract_address().into();
            let (bid_base, bid_quote, bid_base_fees, bid_quote_fees) = market_manager
                .amounts_inside_position(market_id, contract, bid_lower, bid_upper);
            let (ask_base, ask_quote, ask_base_fees, ask_quote_fees) = market_manager
                .amounts_inside_position(market_id, contract, ask_lower, ask_upper);

            // Update positions.
            let placed_positions = self.placed_positions(market_id);
            let mut bid = *placed_positions.at(0);
            let mut ask = *placed_positions.at(1);
            if rebalance {
                // Rebalance bid.
                let floored_curr_limit = trend_math::floor_limit(
                    market_state.curr_limit, market_info.width
                );
                let bid_lower = if floored_curr_limit < state.range {
                    0
                } else {
                    floored_curr_limit - state.range
                };
                let quote_amount = state.quote_reserves
                    + bid_quote
                    + bid_quote_fees
                    + ask_quote
                    + ask_quote_fees;
                let bid_upper = floored_curr_limit;
                let bid_liquidity = if quote_amount == 0 || bid_lower == 0 || bid_upper == 0 {
                    0
                } else {
                    liquidity_math::quote_to_liquidity(
                        price_math::limit_to_sqrt_price(bid_lower, market_info.width),
                        price_math::limit_to_sqrt_price(bid_upper, market_info.width),
                        quote_amount,
                        false
                    )
                };
                bid =
                    PositionInfo {
                        lower_limit: bid_lower, upper_limit: bid_upper, liquidity: bid_liquidity,
                    };

                // Rebalance ask.
                let ceiled_ask_lower = trend_math::ceil_limit(
                    market_state.curr_limit, market_info.width
                );
                let ask_lower = ceiled_ask_lower;
                let ask_upper = min(
                    ceiled_ask_lower + state.range, price_math::max_limit(market_info.width)
                );
                let base_amount = state.base_reserves
                    + ask_base
                    + ask_base_fees
                    + bid_base
                    + bid_base_fees;
                let ask_liquidity = if base_amount == 0 || ask_lower == 0 || ask_upper == 0 {
                    0
                } else {
                    liquidity_math::base_to_liquidity(
                        price_math::limit_to_sqrt_price(ask_lower, market_info.width),
                        price_math::limit_to_sqrt_price(ask_upper, market_info.width),
                        base_amount,
                        false
                    )
                };
                ask =
                    PositionInfo {
                        lower_limit: ask_lower, upper_limit: ask_upper, liquidity: ask_liquidity,
                    };
            }
            // Return positions.
            array![bid, ask].span()
        }

        // Called by `MarketManager` before swap to replace `placed_positions` with `queued_positions`.
        // If the two are identical, no positions will be updated.
        fn update_positions(ref self: ContractState, market_id: felt252, params: SwapParams) {
            // Run checks
            let market_manager = self.market_manager.read();
            assert(get_caller_address() == market_manager.contract_address, 'OnlyMarketManager');
            let state = self.strategy_state.read(market_id);
            if !state.is_initialised || state.is_paused {
                return;
            }

            // Check whether strategy will rebalance.
            self._update_positions(market_id, Option::Some(params));
        }
    }

    #[abi(embed_v0)]
    impl ReversionStrategy of ITrendStrategy<ContractState> {
        // Contract owner
        fn owner(self: @ContractState) -> ContractAddress {
            self.owner.read()
        }

        // Queued contract owner, used for ownership transfers
        fn queued_owner(self: @ContractState) -> ContractAddress {
            self.queued_owner.read()
        }

        // Trend
        fn trend(self: @ContractState, market_id: felt252) -> Trend {
            self.strategy_state.read(market_id).trend
        }

        // Strategy state
        fn strategy_state(self: @ContractState, market_id: felt252) -> StrategyState {
            self.strategy_state.read(market_id)
        }

        // Whether strategy is paused for a given market
        fn is_paused(self: @ContractState, market_id: felt252) -> bool {
            self.strategy_state.read(market_id).is_paused
        }

        // Base reserves of strategy
        fn base_reserves(self: @ContractState, market_id: felt252) -> u256 {
            self.strategy_state.read(market_id).base_reserves
        }

        // Quote reserves of strategy
        fn quote_reserves(self: @ContractState, market_id: felt252) -> u256 {
            self.strategy_state.read(market_id).quote_reserves
        }

        // Withdraw fee rate for a given market
        fn withdraw_fee_rate(self: @ContractState, market_id: felt252) -> u16 {
            self.withdraw_fee_rate.read(market_id)
        }

        // Accumulated withdraw fee balance for a given asset
        fn withdraw_fees(self: @ContractState, token: ContractAddress) -> u256 {
            self.withdraw_fees.read(token)
        }

        // Get total tokens held in strategy, whether in reserves or in positions.
        // 
        // # Arguments
        // * `market_id` - market id
        //
        // # Returns
        // * `base_amount` - total base tokens owned
        // * `quote_amount` - total quote tokens owned
        fn get_balances(self: @ContractState, market_id: felt252) -> (u256, u256) {
            // Fetch strategy state.
            let state = self.strategy_state.read(market_id);
            let bid = state.bid;
            let ask = state.ask;

            // Fetch position info from market manager.
            let market_manager = self.market_manager.read();
            let contract: felt252 = get_contract_address().into();

            // Calculate base and quote amounts inside strategy, either in reserves or in positions.
            let mut base_amount = state.base_reserves;
            let mut quote_amount = state.quote_reserves;

            if bid.upper_limit != 0 {
                let (bid_base, bid_quote, bid_base_fees, bid_quote_fees) = market_manager
                    .amounts_inside_position(market_id, contract, bid.lower_limit, bid.upper_limit);
                base_amount += bid_base + bid_base_fees;
                quote_amount += bid_quote + bid_quote_fees;
            }
            if ask.upper_limit != 0 {
                let (ask_base, ask_quote, ask_base_fees, ask_quote_fees) = market_manager
                    .amounts_inside_position(market_id, contract, ask.lower_limit, ask.upper_limit);
                base_amount += ask_base + ask_base_fees;
                quote_amount += ask_quote + ask_quote_fees;
            }

            (base_amount, quote_amount)
        }

        // Initialise strategy for market.
        // At the moment, only callable by contract owner to prevent unwanted claiming of strategies. 
        //
        // # Arguments
        // * `market_id` - market id
        // * `owner` - owner
        // * `trend` - initial trend
        // * `range` - range parameter (width, in limits, of bid and ask liquidity positions)
        //
        // # Returns
        // * `token_address` - address of strategy token
        fn add_market(
            ref self: ContractState,
            market_id: felt252,
            owner: ContractAddress,
            trend: Trend,
            range: u32,
        ) -> ContractAddress {
            // Run checks.
            self.assert_owner();
            let mut state = self.strategy_state.read(market_id);
            assert(!state.is_initialised, 'Initialised');
            assert(range != 0, 'RangeZero');

            // Check the market exists. This check prevents accidental registration of the wrong market.
            let market_manager = self.market_manager.read();
            let market_info = market_manager.market_info(market_id);
            assert(market_info.width != 0, 'MarketNull');

            // Initialise strategy state.
            state.is_initialised = true;
            state.trend = trend;
            state.range = range;
            self.strategy_state.write(market_id, state);

            // Deploy token to keep track of strategy shares.
            let base_symbol = ERC20ABIDispatcher { contract_address: market_info.base_token }
                .symbol();
            let quote_symbol = ERC20ABIDispatcher { contract_address: market_info.quote_token }
                .symbol();
            let name: ByteArray = format!(
                "Haiko {} {}-{}", self.name.read(), base_symbol, quote_symbol
            );
            let symbol: ByteArray = format!(
                "{}-{}-{}", self.symbol.read(), base_symbol, quote_symbol
            );
            let decimals: u8 = 18;
            let strategy = get_contract_address();
            let mut calldata: Array<felt252> = array![];
            name.serialize(ref calldata);
            symbol.serialize(ref calldata);
            decimals.serialize(ref calldata);
            strategy.serialize(ref calldata);
            let (token, _) = deploy_syscall(
                self.vault_token_class.read(), 0, calldata.span(), false
            )
                .unwrap();
            self.strategy_token.write(market_id, ERC20ABIDispatcher { contract_address: token });

            // Emit events.
            self.emit(Event::AddMarket(AddMarket { market_id, token }));

            self.emit(Event::SetStrategyParams(SetStrategyParams { market_id, trend, range, }));

            // Return token address.
            token
        }

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
            ref self: ContractState, market_id: felt252, base_amount: u256, quote_amount: u256
        ) -> u256 {
            // Run checks
            assert(base_amount != 0 && quote_amount != 0, 'AmountZero');
            let mut state = self.strategy_state.read(market_id);
            assert(state.is_initialised, 'NotInitialised');
            assert(!state.is_paused, 'Paused');
            let token = self.strategy_token.read(market_id);
            assert(token.total_supply() == 0, 'UseDeposit');

            // Fetch dispatchers.
            let market_manager = self.market_manager.read();
            let market_info = market_manager.market_info(market_id);
            let base_token = ERC20ABIDispatcher { contract_address: market_info.base_token };
            let quote_token = ERC20ABIDispatcher { contract_address: market_info.quote_token };

            // Deposit tokens to reserves
            let caller = get_caller_address();
            let contract = get_contract_address();
            base_token.transferFrom(caller, contract, base_amount);
            quote_token.transferFrom(caller, contract, quote_amount);

            // Update reserves. Must be committed to state for `_update_positions` to place positions.
            state.base_reserves += base_amount;
            state.quote_reserves += quote_amount;
            self.strategy_state.write(market_id, state);

            // Approve max spend by market manager. Place initial positions.
            base_token.approve(market_manager.contract_address, BoundedInt::max());
            quote_token.approve(market_manager.contract_address, BoundedInt::max());
            let (bid, ask) = self._update_positions(market_id, Option::None(()));

            // Mint liquidity
            let shares: u256 = (bid.liquidity + ask.liquidity).into();
            IVaultTokenDispatcher { contract_address: token.contract_address }.mint(caller, shares);

            // Emit event
            self
                .emit(
                    Event::Deposit(Deposit { market_id, caller, base_amount, quote_amount, shares })
                );

            shares
        }

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
            ref self: ContractState, market_id: felt252, base_amount: u256, quote_amount: u256
        ) -> (u256, u256, u256) {
            let token = self.strategy_token.read(market_id);
            let total_supply = token.total_supply();
            assert(total_supply != 0, 'UseDepositInitial');
            assert(base_amount != 0 || quote_amount != 0, 'AmountZero');
            let mut state = self.strategy_state.read(market_id);
            assert(!state.is_paused, 'Paused');

            // Fetch market info and strategy state.
            let market_manager = self.market_manager.read();
            let market_info = market_manager.market_info(market_id);
            let (base_balance, quote_balance) = self.get_balances(market_id);

            // Calculate shares to mint.
            let base_deposit = if quote_amount == 0 || quote_balance == 0 {
                base_amount
            } else {
                min(base_amount, math::mul_div(quote_amount, base_balance, quote_balance, false))
            };
            let quote_deposit = if base_amount == 0 || base_balance == 0 {
                quote_amount
            } else {
                min(quote_amount, math::mul_div(base_amount, quote_balance, base_balance, false))
            };
            // Calculate shares on larger (and non-zero) amount for better precision.
            let shares = if quote_balance > base_balance {
                math::mul_div(total_supply, quote_deposit, quote_balance, false)
            } else {
                math::mul_div(total_supply, base_deposit, base_balance, false)
            };

            // Transfer tokens into contract.
            let caller = get_caller_address();
            let contract = get_contract_address();
            if base_deposit != 0 {
                let base_token = ERC20ABIDispatcher { contract_address: market_info.base_token };
                assert(base_token.balanceOf(caller) >= base_deposit, 'DepositBase');
                base_token.transferFrom(caller, contract, base_deposit);
            }
            if quote_deposit != 0 {
                let quote_token = ERC20ABIDispatcher { contract_address: market_info.quote_token };
                assert(quote_token.balanceOf(caller) >= quote_deposit, 'DepositQuote');
                quote_token.transferFrom(caller, contract, quote_deposit);
            }

            // Update reserves.
            state.base_reserves += base_deposit;
            state.quote_reserves += quote_deposit;
            self.strategy_state.write(market_id, state);

            // Update deposits.
            IVaultTokenDispatcher { contract_address: token.contract_address }.mint(caller, shares);

            // Emit event.
            self
                .emit(
                    Event::Deposit(
                        Deposit {
                            market_id,
                            caller,
                            base_amount: base_deposit,
                            quote_amount: quote_deposit,
                            shares,
                        }
                    )
                );

            (base_deposit, quote_deposit, shares)
        }

        // Burn pool shares and withdraw funds from strategy.
        //
        // # Arguments
        // * `market_id` - market id
        // * `shares` - pool shares to burn
        //
        // # Returns
        // * `base_amount` - base asset withdrawn
        // * `quote_amount` - quote asset withdrawn
        fn withdraw(ref self: ContractState, market_id: felt252, shares: u256) -> (u256, u256) {
            // Run checks
            assert(shares != 0, 'SharesZero');
            let caller = get_caller_address();
            let token = self.strategy_token.read(market_id);
            let user_shares = token.balance_of(caller);
            assert(user_shares >= shares, 'InsuffShares');

            // Fetch current market state
            let market_manager = self.market_manager.read();
            let total_supply = token.total_supply();
            let mut state = self.strategy_state.read(market_id);

            // Calculate share of reserves to withdraw
            let mut base_withdraw = math::mul_div(
                state.base_reserves, user_shares, total_supply, false
            );
            let mut quote_withdraw = math::mul_div(
                state.quote_reserves, user_shares, total_supply, false
            );
            state.base_reserves -= base_withdraw;
            state.quote_reserves -= quote_withdraw;

            // Calculate share of position liquidity to withdraw.
            let placed_positions = self.placed_positions(market_id);
            let bid = *placed_positions.at(0);
            let ask = *placed_positions.at(1);
            // Only withdraw if position is non-empty.
            if state.bid.upper_limit != 0 && bid.liquidity != 0 {
                let bid_liquidity_delta = math::mul_div(
                    bid.liquidity.into(), shares, total_supply, false
                );
                let bid_delta_u128: u128 = bid_liquidity_delta.try_into().expect('BidLiqOF');
                let (bid_base_rem, bid_quote_rem, bid_base_fees, bid_quote_fees) = market_manager
                    .modify_position(
                        market_id,
                        state.bid.lower_limit,
                        state.bid.upper_limit,
                        I128Trait::new(bid_delta_u128, true)
                    );
                let base_fees_excess = math::mul_div(
                    bid_base_fees, total_supply - shares, total_supply, true
                );
                let quote_fees_excess = math::mul_div(
                    bid_quote_fees, total_supply - shares, total_supply, true
                );
                base_withdraw += bid_base_rem.val - base_fees_excess;
                quote_withdraw += bid_quote_rem.val - quote_fees_excess;
                state.base_reserves += base_fees_excess;
                state.quote_reserves += quote_fees_excess;
            }
            if state.ask.upper_limit != 0 && ask.liquidity != 0 {
                let ask_liquidity_delta = math::mul_div(
                    ask.liquidity.into(), shares, total_supply, false
                );
                let ask_delta_u128: u128 = ask_liquidity_delta.try_into().expect('AskLiqOF');
                let (ask_base_rem, ask_quote_rem, ask_base_fees, ask_quote_fees) = market_manager
                    .modify_position(
                        market_id,
                        state.ask.lower_limit,
                        state.ask.upper_limit,
                        I128Trait::new(ask_delta_u128, true)
                    );
                let base_fees_excess = math::mul_div(
                    ask_base_fees, total_supply - shares, total_supply, true
                );
                let quote_fees_excess = math::mul_div(
                    ask_quote_fees, total_supply - shares, total_supply, true
                );
                base_withdraw += ask_base_rem.val - base_fees_excess;
                quote_withdraw += ask_quote_rem.val - quote_fees_excess;
                state.base_reserves += base_fees_excess;
                state.quote_reserves += quote_fees_excess;
            }

            // Burn shares.
            IVaultTokenDispatcher { contract_address: token.contract_address }.burn(caller, shares);

            // Initialise withdraw fee balances and cache withdraw amounts gross of fees.
            let mut base_withdraw_fees = 0;
            let mut quote_withdraw_fees = 0;
            let base_withdraw_gross = base_withdraw;
            let quote_withdraw_gross = quote_withdraw;

            // Deduct withdrawal fee.
            let fee_rate = self.withdraw_fee_rate.read(market_id);
            if fee_rate != 0 {
                base_withdraw_fees = fee_math::calc_fee(base_withdraw, fee_rate);
                quote_withdraw_fees = fee_math::calc_fee(quote_withdraw, fee_rate);
                base_withdraw -= base_withdraw_fees;
                quote_withdraw -= quote_withdraw_fees;
            }

            // Update fee balance.
            let market_info = market_manager.market_info(market_id);
            if base_withdraw_fees != 0 {
                let base_fees = self.withdraw_fees.read(market_info.base_token);
                self.withdraw_fees.write(market_info.base_token, base_fees + base_withdraw_fees);
            }
            if quote_withdraw_fees != 0 {
                let quote_fees = self.withdraw_fees.read(market_info.quote_token);
                self.withdraw_fees.write(market_info.quote_token, quote_fees + quote_withdraw_fees);
            }

            // Update reserves.
            self.strategy_state.write(market_id, state);

            // Transfer tokens to caller.
            if base_withdraw != 0 {
                let base_token = ERC20ABIDispatcher { contract_address: market_info.base_token };
                base_token.transfer(caller, base_withdraw);
            }
            if quote_withdraw != 0 {
                let quote_token = ERC20ABIDispatcher { contract_address: market_info.quote_token };
                quote_token.transfer(caller, quote_withdraw);
            }

            // Emit event.
            self
                .emit(
                    Event::Withdraw(
                        Withdraw {
                            market_id,
                            caller,
                            base_amount: base_withdraw_gross,
                            quote_amount: quote_withdraw_gross,
                            shares,
                        }
                    )
                );
            if base_withdraw_fees != 0 {
                self
                    .emit(
                        Event::WithdrawFeeEarned(
                            WithdrawFeeEarned {
                                market_id, token: market_info.base_token, amount: base_withdraw_fees
                            }
                        )
                    );
            }
            if quote_withdraw_fees != 0 {
                self
                    .emit(
                        Event::WithdrawFeeEarned(
                            WithdrawFeeEarned {
                                market_id,
                                token: market_info.quote_token,
                                amount: quote_withdraw_fees
                            }
                        )
                    );
            }

            // Return withdrawn amounts.
            (base_withdraw, quote_withdraw)
        }

        // Manually trigger contract to collect all outstanding positions and pause the contract.
        // Only callable by owner.
        fn collect_and_pause(ref self: ContractState, market_id: felt252) {
            self.assert_owner();
            self._collect_and_pause(market_id);
        }

        // Collect withdrawal fees.
        // Only callable by contract owner.
        //
        // # Arguments
        // * `receiver` - address to receive fees
        // * `token` - token to collect fees for
        // * `amount` - amount of fees requested
        fn collect_withdraw_fees(
            ref self: ContractState, receiver: ContractAddress, token: ContractAddress, amount: u256
        ) -> u256 {
            // Run checks.
            self.assert_owner();
            let mut fees = self.withdraw_fees.read(token);
            assert(fees >= amount, 'InsuffFees');

            // Update fee balance.
            fees -= amount;
            self.withdraw_fees.write(token, fees);

            // Transfer fees to caller.
            let dispatcher = ERC20ABIDispatcher { contract_address: token };
            dispatcher.transfer(get_caller_address(), amount);

            // Emit event.
            self.emit(Event::CollectWithdrawFee(CollectWithdrawFee { receiver, token, amount }));

            // Return amount collected.
            amount
        }

        // Change the parameters of the strategy.
        // Only callable by owner.
        //
        // # Params
        // * `market_id` - market id
        // * `trend` - trend
        // * `range` - range
        fn set_strategy_params(
            ref self: ContractState, market_id: felt252, trend: Trend, range: u32
        ) {
            // Run checks.
            self.assert_owner();
            let mut state = self.strategy_state.read(market_id);
            assert(state.trend != trend || state.range != range, 'ParamsUnchanged');
            assert(range != 0, 'RangeZero');

            // Update strategy params.
            state.queued_trend = trend;
            state.range = range;
            self.strategy_state.write(market_id, state);

            self.emit(Event::SetStrategyParams(SetStrategyParams { market_id, trend, range, }));
        }

        // Set withdraw fee for a given market.
        // Only callable by contract owner.
        //
        // # Arguments
        // * `market_id` - market id
        // * `fee_rate` - fee rate
        fn set_withdraw_fee(ref self: ContractState, market_id: felt252, fee_rate: u16) {
            self.assert_owner();
            let old_fee_rate = self.withdraw_fee_rate.read(market_id);
            assert(old_fee_rate != fee_rate, 'FeeUnchanged');
            assert(fee_rate <= MAX_FEE_RATE, 'FeeOF');
            self.withdraw_fee_rate.write(market_id, fee_rate);
            self.emit(Event::SetWithdrawFee(SetWithdrawFee { market_id, fee_rate }));
        }

        // Request transfer ownership of the contract.
        // Part 1 of 2 step process to transfer ownership.
        //
        // # Arguments
        // * `new_owner` - New owner of the contract
        fn transfer_owner(ref self: ContractState, new_owner: ContractAddress) {
            self.assert_owner();
            let old_owner = self.owner.read();
            assert(new_owner != old_owner, 'SameOwner');
            self.queued_owner.write(new_owner);
        }

        // Called by new owner to accept ownership of the contract.
        // Part 2 of 2 step process to transfer ownership.
        fn accept_owner(ref self: ContractState) {
            let queued_owner = self.queued_owner.read();
            assert(get_caller_address() == queued_owner, 'OnlyNewOwner');
            let old_owner = self.owner.read();
            self.owner.write(queued_owner);
            self.queued_owner.write(contract_address_const::<0x0>());
            self.emit(Event::ChangeOwner(ChangeOwner { old: old_owner, new: queued_owner }));
        }

        // Pause strategy. 
        // Only callable by owner. 
        // 
        // # Arguments
        // * `market_id` - market id of strategy
        fn pause(ref self: ContractState, market_id: felt252) {
            self.assert_owner();
            let mut state = self.strategy_state.read(market_id);
            assert(!state.is_paused, 'AlreadyPaused');
            state.is_paused = true;
            self.strategy_state.write(market_id, state);
            self.emit(Event::Pause(Pause { market_id }));
        }

        // Unpause strategy.
        // Only callable by owner.
        //
        // # Arguments
        // * `market_id` - market id of strategy
        fn unpause(ref self: ContractState, market_id: felt252) {
            self.assert_owner();
            let mut state = self.strategy_state.read(market_id);
            assert(state.is_paused, 'AlreadyUnpaused');
            state.is_paused = false;
            self.strategy_state.write(market_id, state);
            self.emit(Event::Unpause(Unpause { market_id }));
        }

        // Manually trigger contract to update positions.
        // Only callable by owner.
        //
        // # Arguments
        // * `market_id` - market id of strategy
        fn trigger_update_positions(ref self: ContractState, market_id: felt252) {
            // Run checks.
            self.assert_owner();
            let state = self.strategy_state.read(market_id);
            assert(state.is_initialised, 'NotInitialised');
            assert(!state.is_paused, 'Paused');

            // Update positions.
            self._update_positions(market_id, Option::None(()));
        }

        // Upgrade contract class.
        // Callable by owner only.
        //
        // # Arguments
        // * `new_class_hash` - new class hash of contract
        fn upgrade(ref self: ContractState, new_class_hash: ClassHash) {
            self.assert_owner();
            replace_class_syscall(new_class_hash).unwrap();
            self.emit(Event::Upgraded(Upgraded { class_hash: new_class_hash }));
        }
    }

    ////////////////////////////////
    // INTERNAL FUNCTIONS
    ////////////////////////////////

    #[generate_trait]
    impl InternalImpl of InternalTrait {
        // Internal function to update for new optimal bid and ask positions.
        //
        // # Arguments
        // * `market_id` - market id of strategy
        // * `swap_params` - (optional) swap params
        //
        // # Returns
        // * `bid` - new bid position
        // * `ask` - new ask position
        fn _update_positions(
            ref self: ContractState, market_id: felt252, swap_params: Option<SwapParams>
        ) -> (PositionInfo, PositionInfo) {
            // Fetch market and strategy state.
            let market_manager = self.market_manager.read();
            let mut state = self.strategy_state.read(market_id);

            // Compare placed and queued positions.
            // If the old positions are the same as the new positions, no updates will be made.
            let placed_positions = self.placed_positions(market_id);
            let queued_positions = self.queued_positions(market_id, swap_params);
            let mut bid = *placed_positions.at(0);
            let mut ask = *placed_positions.at(1);
            let next_bid = *queued_positions.at(0);
            let next_ask = *queued_positions.at(1);
            // println!("[placed] bid_lower: {}, bid_upper: {}, bid_liquidity: {}", bid.lower_limit, bid.upper_limit, bid.liquidity);
            // println!("[placed] ask_lower: {}, ask_upper: {}, ask_liquidity: {}", ask.lower_limit, ask.upper_limit, ask.liquidity);
            // println!("[queued] bid_lower: {}, bid_upper: {}, bid_liquidity: {}", next_bid.lower_limit, next_bid.upper_limit, next_bid.liquidity);
            // println!("[queued] ask_lower: {}, ask_upper: {}, ask_liquidity: {}", next_ask.lower_limit, next_ask.upper_limit, next_ask.liquidity);
            let update_bid: bool = next_bid.lower_limit != bid.lower_limit
                || next_bid.upper_limit != bid.upper_limit;
            let update_ask: bool = next_ask.lower_limit != ask.lower_limit
                || next_ask.upper_limit != ask.upper_limit;

            // Update positions.
            // If old positions exist at different price ranges, first remove them.
            if bid.liquidity != 0 && update_bid {
                let (base_amount, quote_amount, _, _) = market_manager
                    .modify_position(
                        market_id,
                        bid.lower_limit,
                        bid.upper_limit,
                        I128Trait::new(bid.liquidity, true)
                    );
                state.base_reserves += base_amount.val;
                state.quote_reserves += quote_amount.val;
                bid = Default::default();
            }
            if ask.liquidity != 0 && update_ask {
                let (base_amount, quote_amount, _, _) = market_manager
                    .modify_position(
                        market_id,
                        ask.lower_limit,
                        ask.upper_limit,
                        I128Trait::new(ask.liquidity, true)
                    );
                state.base_reserves += base_amount.val;
                state.quote_reserves += quote_amount.val;
                ask = Default::default();
            }

            // Place new positions.
            if next_bid.liquidity != 0 && update_bid {
                let (_, quote_amount, _, _) = market_manager
                    .modify_position(
                        market_id,
                        next_bid.lower_limit,
                        next_bid.upper_limit,
                        I128Trait::new(next_bid.liquidity, false)
                    );
                state.quote_reserves -= quote_amount.val;
                bid = next_bid;
            };
            if next_ask.liquidity != 0 && update_ask {
                let (base_amount, _, _, _) = market_manager
                    .modify_position(
                        market_id,
                        next_ask.lower_limit,
                        next_ask.upper_limit,
                        I128Trait::new(next_ask.liquidity, false)
                    );
                state.base_reserves -= base_amount.val;
                ask = next_ask;
            }

            // Commit state updates
            // If trend has changed, update it.
            if state.trend != state.queued_trend {
                state.trend = state.queued_trend;
            }
            state.bid.lower_limit = bid.lower_limit;
            state.bid.upper_limit = bid.upper_limit;
            state.ask.lower_limit = ask.lower_limit;
            state.ask.upper_limit = ask.upper_limit;
            self.strategy_state.write(market_id, state);

            // Emit event if positions have changed.
            if update_bid || update_ask {
                self
                    .emit(
                        Event::UpdatePositions(
                            UpdatePositions {
                                market_id,
                                bid_lower_limit: bid.lower_limit,
                                bid_upper_limit: bid.upper_limit,
                                bid_liquidity: bid.liquidity,
                                ask_lower_limit: ask.lower_limit,
                                ask_upper_limit: ask.upper_limit,
                                ask_liquidity: ask.liquidity,
                            }
                        )
                    );
            }

            (bid, ask)
        }

        // Internal function to collect all outstanding positions and pause the contract.
        // 
        // # Arguments
        // * `market_id` - market id
        fn _collect_and_pause(ref self: ContractState, market_id: felt252) {
            let mut state = self.strategy_state.read(market_id);
            assert(state.is_initialised, 'NotInitialised');
            assert(!state.is_paused, 'AlreadyPaused');

            let market_manager = self.market_manager.read();

            // Fetch existing positions.
            let placed_positions = self.placed_positions(market_id);
            let mut bid = *placed_positions.at(0);
            let mut ask = *placed_positions.at(1);

            // Remove existing positions.
            if bid.liquidity != 0 {
                let (bid_base, bid_quote, _, _) = market_manager
                    .modify_position(
                        market_id,
                        bid.lower_limit,
                        bid.upper_limit,
                        I128Trait::new(bid.liquidity, true)
                    );
                state.base_reserves += bid_base.val;
                state.quote_reserves += bid_quote.val;
                bid = Default::default();
            }
            if ask.liquidity != 0 {
                let (ask_base, ask_quote, _, _) = market_manager
                    .modify_position(
                        market_id,
                        ask.lower_limit,
                        ask.upper_limit,
                        I128Trait::new(ask.liquidity, true)
                    );
                state.base_reserves += ask_base.val;
                state.quote_reserves += ask_quote.val;
                ask = Default::default();
            }

            // Commit state updates
            state.is_paused = true;
            state.bid.lower_limit = bid.lower_limit;
            state.bid.upper_limit = bid.upper_limit;
            state.ask.lower_limit = ask.lower_limit;
            state.ask.upper_limit = ask.upper_limit;
            self.strategy_state.write(market_id, state);

            self.emit(Event::Pause(Pause { market_id }));
        }
    }
}
