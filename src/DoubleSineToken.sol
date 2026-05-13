// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Hooks} from "v4-core/libraries/Hooks.sol";

import {IDoubleSineHookBinding} from "./IDoubleSineHookBinding.sol";

/// @notice Plain ERC20 for the DoubleSine pair. Tokens are freely
/// transferable so external DEXs, aggregators, and wallets can route them
/// normally. The "entanglement" invariant lives in the canonical v4 hook
/// (the Collider/AMM), not in transfer restrictions.
///
/// PoolManager and the canonical router are constructor-bound for binding
/// validation, and the hook is added once through bindHook. Mint/burn remains
/// hook-only so supply changes are controlled by the canonical curve.
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

    event Transfer(address indexed from, address indexed to, uint256 amount);
    event Approval(address indexed owner, address indexed spender, uint256 amount);
    event HookBound(address indexed hook);

    error AlreadyBound();
    error NotBinder();
    error NotHook();
    error InsufficientBalance();
    error InsufficientAllowance();
    error ZeroAddress();
    error SystemAddressMustHaveCode();
    error HookMustHaveCode();
    error InvalidHookBinding();

    constructor(string memory name_, string memory symbol_, address poolManager_, address router_) {
        if (poolManager_ == address(0) || router_ == address(0)) revert ZeroAddress();
        if (poolManager_.code.length == 0 || router_.code.length == 0) revert SystemAddressMustHaveCode();
        name = name_;
        symbol = symbol_;
        poolManager = poolManager_;
        router = router_;
        binder = msg.sender;
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
        (address hookManager, address hookRouter, address hookTokenA, address hookTokenB) = _readHookBinding(newHook);
        if (
            hookManager != poolManager || hookRouter != router
                || (hookTokenA != address(this) && hookTokenB != address(this))
        ) {
            revert InvalidHookBinding();
        }
        hook = newHook;
        binder = address(0);
        emit HookBound(newHook);
    }

    function approve(address spender, uint256 amount) external returns (bool) {
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
        // delivers tokens to users via the v4 settle/transfer path.
        // Restricting here removes any "what if a buggy hook minted to a
        // bad address" surface.
        if (to != hook) revert NotHook();
        totalSupply += amount;
        balanceOf[to] += amount;
        emit Transfer(address(0), to, amount);
    }

    function burn(address from, uint256 amount) external onlyHook {
        // Sells settle tokens into the hook first, then burn from hook
        // custody. Keep burn authority symmetric with mint authority so the
        // hook cannot ever claw back tokens from users or external venues.
        if (from != hook) revert NotHook();
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
        uint256 balance = balanceOf[from];
        if (balance < amount) revert InsufficientBalance();
        unchecked {
            balanceOf[from] = balance - amount;
            balanceOf[to] += amount;
        }
        emit Transfer(from, to, amount);
    }

    function _readHookBinding(address hook_)
        private
        view
        returns (address hookManager, address hookRouter, address hookTokenA, address hookTokenB)
    {
        IDoubleSineHookBinding hookBinding = IDoubleSineHookBinding(hook_);
        try hookBinding.manager() returns (address manager_) {
            hookManager = manager_;
        } catch {
            revert InvalidHookBinding();
        }
        try hookBinding.router() returns (address router_) {
            hookRouter = router_;
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
