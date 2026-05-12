// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Hooks} from "v4-core/libraries/Hooks.sol";

import {IDoubleSineHookBinding} from "./IDoubleSineHookBinding.sol";

/// @notice ERC20 with a no-arbitrage transfer rule: tokens may only move
/// between externally-owned accounts (no code) or addresses on a fixed
/// authorized contract list. This makes deployed external pools (v2 Pair,
/// v3 Pool, CEX deposit, lending markets) unable to receive or move the token,
/// so the canonical hook pool is the only supported market.
///
/// Authorized set is locked at construction: PoolManager and the canonical
/// router are constructor-bound, the hook is added once through bindHook,
/// and optional integration contracts can be listed at deploy time. Because
/// Uniswap v4 uses one singleton PoolManager for all pools, deposits into
/// PoolManager are further restricted to this router/hook settlement path.
contract DoubleSineToken {
    string public name;
    string public symbol;
    uint8 public constant decimals = 18;
    uint160 internal constant REQUIRED_HOOK_FLAGS = uint160(
        Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
            | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
    );

    uint256 public totalSupply;
    address public immutable poolManager;
    address public immutable router;
    address public hook;
    address private binder;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    mapping(address => bool) public isAuthorized;

    event Transfer(address indexed from, address indexed to, uint256 amount);
    event Approval(address indexed owner, address indexed spender, uint256 amount);
    event HookBound(address indexed hook);
    event Authorized(address indexed account);

    error AlreadyBound();
    error NotBinder();
    error NotHook();
    error InsufficientBalance();
    error InsufficientAllowance();
    error ZeroAddress();
    error AuthorizedMustHaveCode();
    error SystemAddressMustHaveCode();
    error HookMustHaveCode();
    error InvalidHookBinding();
    error UnauthorizedContractCaller();
    error TransferFromUnauthorizedContract();
    error TransferToUnauthorizedContract();

    constructor(
        string memory name_,
        string memory symbol_,
        address poolManager_,
        address router_,
        address[] memory authorized_
    ) {
        if (poolManager_ == address(0) || router_ == address(0)) revert ZeroAddress();
        if (poolManager_.code.length == 0 || router_.code.length == 0) revert SystemAddressMustHaveCode();
        name = name_;
        symbol = symbol_;
        poolManager = poolManager_;
        router = router_;
        binder = msg.sender;
        isAuthorized[poolManager_] = true;
        isAuthorized[router_] = true;
        emit Authorized(poolManager_);
        emit Authorized(router_);
        for (uint256 i = 0; i < authorized_.length; i++) {
            if (authorized_[i] == address(0)) revert ZeroAddress();
            if (authorized_[i].code.length == 0) revert AuthorizedMustHaveCode();
            isAuthorized[authorized_[i]] = true;
            emit Authorized(authorized_[i]);
        }
    }

    modifier onlyHook() {
        if (msg.sender != hook) revert NotHook();
        _;
    }

    function bindHook(address newHook) external {
        if (msg.sender != binder) revert NotBinder();
        if (hook != address(0)) revert AlreadyBound();
        if (newHook == address(0)) revert ZeroAddress();
        if (newHook.code.length == 0) revert HookMustHaveCode();
        if ((uint160(newHook) & Hooks.ALL_HOOK_MASK) != REQUIRED_HOOK_FLAGS) revert InvalidHookBinding();
        (address hookManager, address hookTokenA, address hookTokenB) = _readHookBinding(newHook);
        if (hookManager != poolManager || (hookTokenA != address(this) && hookTokenB != address(this))) {
            revert InvalidHookBinding();
        }
        hook = newHook;
        isAuthorized[newHook] = true;
        binder = address(0);
        emit HookBound(newHook);
        emit Authorized(newHook);
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        _requireEOAOrAuthorizedCaller();
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) {
            if (allowed < amount) revert InsufficientAllowance();
            unchecked {
                allowance[from][msg.sender] = allowed - amount;
            }
            emit Approval(from, msg.sender, allowed - amount);
        }
        _transfer(from, to, amount);
        return true;
    }

    function mint(address to, uint256 amount) external onlyHook {
        // Constrain mint destination to the hook itself. The hook then
        // delivers tokens to users via the v4 settle/transfer path, which
        // is gated by the no-arb transfer rule. Restricting here removes
        // any "what if a buggy hook minted to a bad address" surface.
        if (to != hook) revert NotHook();
        totalSupply += amount;
        balanceOf[to] += amount;
        emit Transfer(address(0), to, amount);
    }

    function burn(address from, uint256 amount) external onlyHook {
        uint256 balance = balanceOf[from];
        if (balance < amount) revert InsufficientBalance();
        unchecked {
            balanceOf[from] = balance - amount;
            totalSupply -= amount;
        }
        emit Transfer(from, address(0), amount);
    }

    function _transfer(address from, address to, uint256 amount) internal {
        if (from == address(0)) revert ZeroAddress();
        if (to == address(0)) revert ZeroAddress();
        _requireEOAOrAuthorizedCaller();
        // v4 PoolManager is a singleton shared by every v4 pool. Keep it
        // authorized for canonical settlement, but only let this system's
        // router/hook push tokens into it; otherwise anyone could seed an
        // external v4 pool and bypass the canonical hook market.
        if (to == poolManager && msg.sender != router && msg.sender != hook) {
            revert TransferToUnauthorizedContract();
        }
        // No-arb gate: deployed contracts must be whitelisted on both sides;
        // EOAs have no code and pass. Checking `from` also prevents tokens
        // that somehow reached an unauthorized contract from being moved back
        // out through a non-canonical venue.
        if (from.code.length != 0 && !isAuthorized[from]) {
            revert TransferFromUnauthorizedContract();
        }
        if (to.code.length != 0 && !isAuthorized[to]) {
            revert TransferToUnauthorizedContract();
        }
        uint256 balance = balanceOf[from];
        if (balance < amount) revert InsufficientBalance();
        unchecked {
            balanceOf[from] = balance - amount;
            balanceOf[to] += amount;
        }
        emit Transfer(from, to, amount);
    }

    function _requireEOAOrAuthorizedCaller() private view {
        if (isAuthorized[msg.sender]) return;
        // This is not an ownership check. It blocks contract and in-constructor
        // callers from abusing the EOA code-length exception in the transfer gate.
        // slither-disable-next-line tx-origin
        // solhint-disable-next-line avoid-tx-origin
        if (msg.sender != tx.origin) revert UnauthorizedContractCaller();
    }

    function _readHookBinding(address hook_)
        private
        view
        returns (address hookManager, address hookTokenA, address hookTokenB)
    {
        IDoubleSineHookBinding hookBinding = IDoubleSineHookBinding(hook_);
        try hookBinding.manager() returns (address manager_) {
            hookManager = manager_;
        } catch {
            revert InvalidHookBinding();
        }
        try hookBinding.tokenA() returns (address tokenA_) {
            hookTokenA = tokenA_;
        } catch {
            revert InvalidHookBinding();
        }
        try hookBinding.tokenB() returns (address tokenB_) {
            hookTokenB = tokenB_;
        } catch {
            revert InvalidHookBinding();
        }
    }
}
