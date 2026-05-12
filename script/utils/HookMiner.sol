// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Hooks} from "v4-core/libraries/Hooks.sol";

/// @notice Minimal CREATE2 salt miner for Uniswap v4 hooks. Finds a salt
/// such that CREATE2(deployer, salt, init_code) yields an address whose
/// low 14 bits equal `flags`. v4's PoolManager rejects swaps unless the
/// hook address self-encodes its permissions in those bits.
///
/// Vendored from Uniswap v4-periphery to avoid pulling the full lib.
library HookMiner {
    uint160 constant FLAG_MASK = Hooks.ALL_HOOK_MASK;
    uint256 constant MAX_LOOP  = 160_444;

    function find(
        address deployer,
        uint160 flags,
        bytes memory creationCode,
        bytes memory constructorArgs
    ) internal view returns (address hook, bytes32 salt) {
        flags = flags & FLAG_MASK;
        bytes memory initCode = abi.encodePacked(creationCode, constructorArgs);

        for (uint256 s; s < MAX_LOOP; s++) {
            address candidate = computeAddress(deployer, s, initCode);
            if (uint160(candidate) & FLAG_MASK == flags && candidate.code.length == 0) {
                // forge-lint: disable-next-line(unsafe-typecast)
                return (candidate, bytes32(s));
            }
        }
        revert("HookMiner: no salt found");
    }

    function computeAddress(address deployer, uint256 salt, bytes memory initCode)
        internal
        pure
        returns (address)
    {
        return address(
            uint160(
                uint256(
                    keccak256(
                        abi.encodePacked(bytes1(0xFF), deployer, salt, keccak256(initCode))
                    )
                )
            )
        );
    }
}
