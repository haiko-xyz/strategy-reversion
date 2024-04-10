// Core lib imports.
use starknet::ContractAddress;

// Local imports.
use haiko_strategy_trend::contracts::strategy::TrendStrategy;
use haiko_strategy_trend::types::{Trend, StrategyState};
use haiko_strategy_trend::interfaces::{
    ITrendStrategy::{ITrendStrategyDispatcher, ITrendStrategyDispatcherTrait},
    IVaultToken::{IVaultTokenDispatcher, IVaultTokenDispatcherTrait}
};
use haiko_strategy_trend::tests::helpers::deploy_trend_strategy;

// Haiko imports.
use haiko_lib::types::core::{MarketState, PositionInfo};
use haiko_lib::interfaces::{
    IMarketManager::{IMarketManagerDispatcher, IMarketManagerDispatcherTrait},
    IStrategy::{IStrategyDispatcher, IStrategyDispatcherTrait},
};
use haiko_lib::helpers::params::{
    CreateMarketParams, ModifyPositionParams, SwapParams, SwapMultipleParams, TransferOwnerParams,
    owner, alice, bob, default_token_params, default_market_params
};
use haiko_lib::helpers::utils::{to_e18, approx_eq_pct, approx_eq};
use haiko_lib::helpers::actions::{
    token::{approve, deploy_token, fund}, market_manager::{create_market, deploy_market_manager}
};

// External imports.
use snforge_std::{
    declare, start_prank, stop_prank, CheatTarget, spy_events, SpyOn, EventSpy, EventAssertions,
    EventFetcher
};
use openzeppelin::token::erc20::interface::{ERC20ABIDispatcher, ERC20ABIDispatcherTrait};

////////////////////////////////
// SETUP
////////////////////////////////

fn _before(
    initialise_market: bool,
) -> (
    IMarketManagerDispatcher,
    ERC20ABIDispatcher,
    ERC20ABIDispatcher,
    felt252,
    ITrendStrategyDispatcher,
    Option<ERC20ABIDispatcher>,
) {
    // Deploy market manager.
    let market_manager_class = declare("MarketManager");
    let market_manager = deploy_market_manager(market_manager_class, owner());

    // Deploy tokens.
    let (_treasury, mut base_token_params, mut quote_token_params) = default_token_params();
    let erc20_class = declare("ERC20");
    let base_token = deploy_token(erc20_class, @base_token_params);
    let quote_token = deploy_token(erc20_class, @quote_token_params);

    // Deploy vault token and strategy.
    let vault_token_class = declare("VaultToken");
    let strategy = deploy_trend_strategy(
        owner(), market_manager.contract_address, vault_token_class.class_hash
    );

    // Create market.
    let mut params = default_market_params();
    params.width = 10;
    params.base_token = base_token.contract_address;
    params.quote_token = quote_token.contract_address;
    params.start_limit = 7906620 + 0;
    params.strategy = strategy.contract_address;
    let market_id = create_market(market_manager, params);

    // Add market to strategy.
    let mut token = Option::None(());
    if initialise_market {
        start_prank(CheatTarget::One(strategy.contract_address), owner());
        let token_address = strategy.add_market(market_id, owner(), Trend::Range, 5000);
        token = Option::Some(ERC20ABIDispatcher { contract_address: token_address });
    }

    // Fund owner with initial token balances and approve strategy and market manager as spenders.
    let base_amount = to_e18(5000000);
    let quote_amount = to_e18(1000000000000);
    fund(base_token, owner(), base_amount);
    fund(quote_token, owner(), quote_amount);
    approve(base_token, owner(), market_manager.contract_address, base_amount);
    approve(quote_token, owner(), market_manager.contract_address, quote_amount);
    approve(base_token, owner(), strategy.contract_address, base_amount);
    approve(quote_token, owner(), strategy.contract_address, quote_amount);

    // Fund LP with initial token balances and approve strategy and market manager as spenders.
    fund(base_token, alice(), base_amount);
    fund(quote_token, alice(), quote_amount);
    approve(base_token, alice(), market_manager.contract_address, base_amount);
    approve(quote_token, alice(), market_manager.contract_address, quote_amount);
    approve(base_token, alice(), strategy.contract_address, base_amount);
    approve(quote_token, alice(), strategy.contract_address, quote_amount);

    // Fund strategy with initial token balances and approve market manager as spender.
    // This is due to a limitation with `snforge` pranks that requires the strategy to be the 
    // address executing swaps for checks to pass.
    fund(base_token, strategy.contract_address, base_amount);
    fund(quote_token, strategy.contract_address, quote_amount);
    approve(base_token, strategy.contract_address, market_manager.contract_address, base_amount);
    approve(quote_token, strategy.contract_address, market_manager.contract_address, quote_amount);

    (market_manager, base_token, quote_token, market_id, strategy, token)
}

fn before() -> (
    IMarketManagerDispatcher,
    ERC20ABIDispatcher,
    ERC20ABIDispatcher,
    felt252,
    ITrendStrategyDispatcher,
    ERC20ABIDispatcher,
) {
    let (market_manager, base_token, quote_token, market_id, strategy, token) = _before(true);
    (market_manager, base_token, quote_token, market_id, strategy, token.unwrap())
}

fn before_skip_initialise() -> (
    IMarketManagerDispatcher,
    ERC20ABIDispatcher,
    ERC20ABIDispatcher,
    felt252,
    ITrendStrategyDispatcher,
) {
    let (market_manager, base_token, quote_token, market_id, strategy, _) = _before(false);
    (market_manager, base_token, quote_token, market_id, strategy)
}

////////////////////////////////
// SETUP
////////////////////////////////

#[test]
fn test_add_market_initialises_immutables() {
    let (_market_manager, _base_token, _quote_token, market_id, strategy) =
        before_skip_initialise();

    // Record events.
    let mut spy = spy_events(SpyOn::One(strategy.contract_address));

    // Add market to strategy.
    start_prank(CheatTarget::One(strategy.contract_address), owner());
    let token_address = strategy.add_market(market_id, owner(), Trend::Range, 5000);

    // Check token was created.
    let token = ERC20ABIDispatcher { contract_address: token_address };
    assert(token.name() == "Haiko Trend ETH-USDC", 'Token name');
    assert(token.symbol() == "TRND-ETH-USDC", 'Token symbol');
    assert(token.decimals() == 18, 'Token decimals');
    assert(token.total_supply() == 0, 'Token total supply');

    // Check strategy params and state correctly updated.
    let state = strategy.strategy_state(market_id);
    let placed_positions = IStrategyDispatcher { contract_address: strategy.contract_address }
        .placed_positions(market_id);
    let bid = *placed_positions.at(0);
    let ask = *placed_positions.at(1);
    assert(state.trend == Trend::Range, 'Trend');
    assert(state.range == 5000, 'Range');
    assert(state.is_initialised, 'Initialised');
    assert(!state.is_paused, 'Paused');
    assert(state.base_reserves == 0, 'Base reserves');
    assert(state.quote_reserves == 0, 'Quote reserves');
    assert(bid.lower_limit == 0, 'Bid: lower limit');
    assert(bid.upper_limit == 0, 'Bid: upper limit');
    assert(bid.liquidity == 0, 'Bid: liquidity');
    assert(ask.lower_limit == 0, 'Ask: lower limit');
    assert(ask.upper_limit == 0, 'Ask: upper limit');
    assert(ask.liquidity == 0, 'Ask: liquidity');

    // Check events emitted.
    spy
        .assert_emitted(
            @array![
                (
                    strategy.contract_address,
                    TrendStrategy::Event::AddMarket(
                        TrendStrategy::AddMarket { market_id, token: token_address }
                    )
                )
            ]
        );
}

#[test]
fn test_deposit_initial_success() {
    let (market_manager, base_token, quote_token, market_id, strategy, token) = before();

    // Snapshot before.
    let bef = _snapshot_state(
        market_manager, strategy, market_id, base_token, quote_token, owner()
    );

    // Log events.
    let mut spy = spy_events(SpyOn::One(strategy.contract_address));

    // Deposit initial.
    start_prank(CheatTarget::One(strategy.contract_address), owner());
    let initial_base_amount = to_e18(500000);
    let initial_quote_amount = to_e18(1000000);
    let shares = strategy.deposit_initial(market_id, initial_base_amount, initial_quote_amount);

    // Snapshot after.
    let aft = _snapshot_state(
        market_manager, strategy, market_id, base_token, quote_token, owner()
    );
    let user_balance = token.balance_of(owner());
    let total_supply = token.total_supply();

    // Run checks.
    assert(aft.lp_base_bal == bef.lp_base_bal - initial_base_amount, 'Owner base balance');
    assert(aft.lp_quote_bal == bef.lp_quote_bal - initial_quote_amount, 'Owner quote balance');

    assert(aft.strategy_base_bal == bef.strategy_base_bal, 'Strategy base balance');
    assert(aft.strategy_quote_bal == bef.strategy_quote_bal, 'Strategy quote balance');
    assert(aft.market_base_bal == bef.market_base_bal + initial_base_amount, 'Market base balance');
    assert(
        aft.market_quote_bal == bef.market_quote_bal + initial_quote_amount, 'Market quote balance'
    );
    assert(aft.market_base_res == initial_base_amount, 'Market base reserves');
    assert(aft.market_quote_res == initial_quote_amount, 'Market quote reserves');
    assert(aft.strategy_state.base_reserves == bef.strategy_state.base_reserves, 'Base reserves');
    assert(
        aft.strategy_state.quote_reserves == bef.strategy_state.quote_reserves, 'Quote reserves'
    );
    assert(aft.bid.lower_limit == 7906620 - 5000, 'Bid: lower limit');
    assert(aft.bid.upper_limit == 7906620 + 0, 'Bid: upper limit');
    assert(aft.ask.lower_limit == 7906620 + 10, 'Ask: lower limit');
    assert(aft.ask.upper_limit == 7906620 + 5010, 'Ask: upper limit');
    assert(shares != 0, 'Shares');
    assert(shares == user_balance, 'User deposits');
    assert(shares == total_supply, 'Total deposits');

    // Check event emitted.
    spy
        .assert_emitted(
            @array![
                (
                    strategy.contract_address,
                    TrendStrategy::Event::Deposit(
                        TrendStrategy::Deposit {
                            market_id,
                            caller: owner(),
                            base_amount: initial_base_amount,
                            quote_amount: initial_quote_amount,
                            shares,
                        }
                    )
                )
            ]
        );
}

#[test]
#[should_panic(expected: ('OnlyStrategy',))]
fn test_unqualified_mint_fails() {
    let (_market_manager, _base_token, _quote_token, _market_id, _strategy, token) = before();

    // Attempt to mint.
    start_prank(CheatTarget::One(token.contract_address), alice());
    let token_alt = IVaultTokenDispatcher { contract_address: token.contract_address };
    token_alt.mint(alice(), 1000);
}

#[test]
#[should_panic(expected: ('OnlyStrategy',))]
fn test_unqualified_burn_fails() {
    let (_market_manager, _base_token, _quote_token, market_id, strategy, token) = before();

    // Deposit initial.
    start_prank(CheatTarget::One(strategy.contract_address), alice());
    let initial_base_amount = to_e18(500000);
    let initial_quote_amount = to_e18(1000000);
    strategy.deposit_initial(market_id, initial_base_amount, initial_quote_amount);

    // Attempt to burn.
    start_prank(CheatTarget::One(token.contract_address), alice());
    let token_alt = IVaultTokenDispatcher { contract_address: token.contract_address };
    token_alt.burn(alice(), 1000);
}

#[test]
fn test_swap_updates_positions() {
    let (market_manager, _base_token, _quote_token, market_id, strategy, _token) = before();

    // Deposit initial.
    start_prank(CheatTarget::One(strategy.contract_address), owner());
    let initial_base_amount = to_e18(500000);
    let initial_quote_amount = to_e18(1000000);
    strategy.deposit_initial(market_id, initial_base_amount, initial_quote_amount);

    // Log events.
    let mut spy = spy_events(SpyOn::One(strategy.contract_address));

    // Execute swap as strategy and check positions updated.
    // This must be done to overcome a limitation with `prank` that causes tx to revert for a 
    // non-strategy caller.
    start_prank(CheatTarget::One(market_manager.contract_address), strategy.contract_address);
    start_prank(CheatTarget::One(strategy.contract_address), market_manager.contract_address);
    let amount = to_e18(50000);
    market_manager
        .swap(market_id, true, amount, true, Option::None(()), Option::None(()), Option::None(()));
    // Strategy only rebalances on second swap.
    market_manager
        .swap(market_id, true, amount, true, Option::None(()), Option::None(()), Option::None(()));

    // Snapshot after.
    let state = strategy.strategy_state(market_id);
    let placed_positions = IStrategyDispatcher { contract_address: strategy.contract_address }
        .placed_positions(market_id);
    let bid = *placed_positions.at(0);
    let ask = *placed_positions.at(1);
    let market_state = market_manager.market_state(market_id);

    // Run checks.
    assert(bid.lower_limit == 7906620 - 4500, 'Bid: lower limit');
    assert(bid.upper_limit == 7906620 + 500, 'Bid: upper limit');
    assert(ask.lower_limit == 7906620 + 510, 'Ask: lower limit');
    assert(ask.upper_limit == 7906620 + 5510, 'Ask: upper limit');
    assert(approx_eq_pct(bid.liquidity.into(), 42421212289961428734226604, 20), 'Bid: liquidity');
    assert(approx_eq_pct(ask.liquidity.into(), 18283825699471975631325298, 20), 'Ask: liquidity');
    assert(market_state.curr_limit == 7906620 + 1053, 'Market: curr limit');
    assert(approx_eq(state.base_reserves, 0, 10), 'Base reserves');
    assert(approx_eq(state.quote_reserves, 0, 10), 'Quote reserves');

    // Check event emitted.
    spy
        .assert_emitted(
            @array![
                (
                    strategy.contract_address,
                    TrendStrategy::Event::UpdatePositions(
                        TrendStrategy::UpdatePositions {
                            market_id,
                            bid_lower_limit: bid.lower_limit,
                            bid_upper_limit: bid.upper_limit,
                            bid_liquidity: bid.liquidity,
                            ask_lower_limit: ask.lower_limit,
                            ask_upper_limit: ask.upper_limit,
                            ask_liquidity: ask.liquidity,
                        }
                    )
                )
            ]
        );
}

#[test]
fn test_set_trend() {
    let (market_manager, _base_token, _quote_token, market_id, strategy, _token) = before();

    // Deposit initial.
    start_prank(CheatTarget::One(strategy.contract_address), owner());
    let initial_base_amount = to_e18(500000);
    let initial_quote_amount = to_e18(1000000);
    strategy.deposit_initial(market_id, initial_base_amount, initial_quote_amount);

    // Log events.
    let mut spy = spy_events(SpyOn::One(strategy.contract_address));

    // Update trend to Up mode, meaning only bids are placed.
    // Update range to 4000.
    start_prank(CheatTarget::One(strategy.contract_address), owner());
    strategy.set_strategy_params(market_id, Trend::Up, 4000);

    // Swap to trigger update.
    start_prank(CheatTarget::One(market_manager.contract_address), strategy.contract_address);
    start_prank(CheatTarget::One(strategy.contract_address), market_manager.contract_address);
    let amount = to_e18(50000);
    market_manager
        .swap(market_id, false, amount, true, Option::None(()), Option::None(()), Option::None(()));

    // Check single-sided position placed.
    let placed_positions = IStrategyDispatcher { contract_address: strategy.contract_address }
        .placed_positions(market_id);
    let bid = *placed_positions.at(0);
    let ask = *placed_positions.at(1);

    // Run checks.
    assert(bid.lower_limit == 7906620 - 4000, 'Bid: lower limit');
    assert(bid.upper_limit == 7906620 + 0, 'Bid: upper limit');
    assert(bid.liquidity != 0, 'Bid: liquidity');
    assert(ask.lower_limit == 7906620 + 10, 'Ask: lower limit');
    assert(ask.upper_limit == 7906620 + 10 + 4000, 'Ask: upper limit');
    assert(ask.liquidity != 0, 'Ask: liquidity');

    // Check event emitted.
    spy
        .assert_emitted(
            @array![
                (
                    strategy.contract_address,
                    TrendStrategy::Event::SetStrategyParams(
                        TrendStrategy::SetStrategyParams {
                            market_id, trend: Trend::Up, range: 4000,
                        }
                    )
                ),
                (
                    strategy.contract_address,
                    TrendStrategy::Event::UpdatePositions(
                        TrendStrategy::UpdatePositions {
                            market_id,
                            bid_lower_limit: bid.lower_limit,
                            bid_upper_limit: bid.upper_limit,
                            bid_liquidity: bid.liquidity,
                            ask_lower_limit: ask.lower_limit,
                            ask_upper_limit: ask.upper_limit,
                            ask_liquidity: ask.liquidity,
                        }
                    )
                )
            ]
        );
}

#[test]
fn test_withdraw() {
    let (market_manager, base_token, quote_token, market_id, strategy, token) = before();

    // Deposit initial.
    start_prank(CheatTarget::One(strategy.contract_address), owner());
    let initial_base_amount = to_e18(500000);
    let initial_quote_amount = to_e18(1000000);
    strategy.deposit_initial(market_id, initial_base_amount, initial_quote_amount);

    // Execute swap sell.
    start_prank(CheatTarget::One(market_manager.contract_address), strategy.contract_address);
    start_prank(CheatTarget::One(strategy.contract_address), market_manager.contract_address);
    let amount = to_e18(5000);
    market_manager
        .swap(market_id, false, amount, true, Option::None(()), Option::None(()), Option::None(()));
    market_manager
        .swap(market_id, false, amount, true, Option::None(()), Option::None(()), Option::None(()));

    // Snapshot before.
    let bef = _snapshot_state(
        market_manager, strategy, market_id, base_token, quote_token, owner()
    );

    // Log events.
    let mut spy = spy_events(SpyOn::One(strategy.contract_address));

    // Withdraw from strategy.
    let user_shares_bef = token.balance_of(owner());
    start_prank(CheatTarget::One(strategy.contract_address), owner());
    let (base_amount, quote_amount) = strategy.withdraw(market_id, user_shares_bef);

    // Snapshot after.
    let aft = _snapshot_state(
        market_manager, strategy, market_id, base_token, quote_token, owner()
    );
    let user_shares_aft = token.balance_of(owner());
    let total_supply_aft = token.total_supply();

    // Run checks.
    assert(approx_eq_pct(aft.lp_base_bal, bef.lp_base_bal + bef.market_base_bal, 20), 'LP base');
    assert(
        approx_eq_pct(aft.lp_quote_bal, bef.lp_quote_bal + bef.market_quote_bal, 20), 'LP quote'
    );
    assert(approx_eq_pct(aft.strategy_base_bal, bef.strategy_base_bal, 20), 'Strategy base');
    assert(approx_eq_pct(aft.strategy_quote_bal, bef.strategy_quote_bal, 20), 'Strategy quote');
    assert(approx_eq(aft.market_base_bal, 0, 10), 'Market base');
    assert(approx_eq(aft.market_quote_bal, 0, 10), 'Market quote');
    assert(approx_eq((aft.bid.liquidity + aft.ask.liquidity).into(), 0, 10), 'Liquidity');
    assert(approx_eq_pct(base_amount, 510000000000000000000000, 20), 'Base amount');
    assert(approx_eq_pct(quote_amount, 990032724922577443550373, 20), 'Quote amount');
    assert(approx_eq(aft.strategy_state.base_reserves, 0, 10), 'Base reserves');
    assert(approx_eq(aft.strategy_state.quote_reserves, 0, 10), 'Quote reserves');
    assert(approx_eq(user_shares_aft, 0, 10), 'User shares');
    assert(approx_eq(total_supply_aft, 0, 10), 'Total shares');

    // Check event emitted.
    spy
        .assert_emitted(
            @array![
                (
                    strategy.contract_address,
                    TrendStrategy::Event::Withdraw(
                        TrendStrategy::Withdraw {
                            market_id,
                            caller: owner(),
                            base_amount,
                            quote_amount,
                            shares: user_shares_bef
                        }
                    )
                )
            ]
        );
}

////////////////////////////////
// HELPERS
////////////////////////////////

#[derive(Drop, Copy, Serde)]
struct Snapshot {
    lp_base_bal: u256,
    lp_quote_bal: u256,
    strategy_base_bal: u256,
    strategy_quote_bal: u256,
    market_base_bal: u256,
    market_quote_bal: u256,
    market_base_res: u256,
    market_quote_res: u256,
    market_state: MarketState,
    strategy_state: StrategyState,
    bid: PositionInfo,
    ask: PositionInfo,
}

fn _snapshot_state(
    market_manager: IMarketManagerDispatcher,
    strategy: ITrendStrategyDispatcher,
    market_id: felt252,
    base_token: ERC20ABIDispatcher,
    quote_token: ERC20ABIDispatcher,
    lp: ContractAddress,
) -> Snapshot {
    let lp_base_bal = base_token.balanceOf(lp);
    let lp_quote_bal = quote_token.balanceOf(lp);
    let strategy_base_bal = base_token.balanceOf(strategy.contract_address);
    let strategy_quote_bal = quote_token.balanceOf(strategy.contract_address);
    let market_base_bal = base_token.balanceOf(market_manager.contract_address);
    let market_quote_bal = quote_token.balanceOf(market_manager.contract_address);
    let market_base_res = market_manager.reserves(base_token.contract_address);
    let market_quote_res = market_manager.reserves(quote_token.contract_address);
    let market_state = market_manager.market_state(market_id);
    let strategy_state = strategy.strategy_state(market_id);
    let placed_positions = IStrategyDispatcher { contract_address: strategy.contract_address }
        .placed_positions(market_id);
    let bid = *placed_positions.at(0);
    let ask = *placed_positions.at(1);

    Snapshot {
        lp_base_bal,
        lp_quote_bal,
        strategy_base_bal,
        strategy_quote_bal,
        market_base_bal,
        market_quote_bal,
        market_base_res,
        market_quote_res,
        market_state,
        strategy_state,
        bid,
        ask,
    }
}
