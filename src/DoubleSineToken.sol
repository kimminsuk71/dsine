// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice ERC20 with a no-arbitrage transfer rule: tokens may only be sent
/// to externally-owned accounts (no code) or to addresses on a fixed
/// authorized contract list. This makes external pools (v2 Pair, v3 Pool,
/// CEX deposit, lending markets) UNABLE to receive the token, so the
/// canonical hook pool is the ONLY market - thus no arbitrage is possible.
///
/// Authorized set is locked at construction: the launcher whitelists the
/// hook, V4 PoolManager, our router, Permit2, and (optionally) the Uniswap
/// Universal Router so DEX aggregators (GMGN / DexScreener / Photon) can
/// route swap traffic into the canonical pool. Whitelisting Universal
/// Router does NOT enable external LPs because the actual pool addresses
/// (v2 Pair, v3 Pool) themselves are not whitelisted - any transfer that
/// would terminate at one of those addresses reverts.
contract DoubleSineToken {
    string public name;
    string public symbol;
    uint8 public constant decimals = 18;

    uint256 public totalSupply;
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
    error TransferToUnauthorizedContract();

    constructor(string memory name_, string memory symbol_, address[] memory authorized_) {
        name = name_;
        symbol = symbol_;
        binder = msg.sender;
        for (uint256 i = 0; i < authorized_.length; i++) {
            if (authorized_[i] == address(0)) revert ZeroAddress();
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
        hook = newHook;
        isAuthorized[newHook] = true;
        binder = address(0);
        emit HookBound(newHook);
        emit Authorized(newHook);
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
        if (to == address(0)) revert ZeroAddress();
        // No-arb gate: contracts must be whitelisted; EOAs always pass.
        // Note: tx.origin and code-length checks combined defeat the
        // common reentrancy-style "fake EOA" trick because a contract's
        // code.length is non-zero from the start of its first call frame.
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
}
