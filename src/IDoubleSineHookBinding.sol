// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice Minimal view interface used during one-time system binding.
/// Return types are addresses because Solidity contract getters ABI-encode
/// contract references as address values.
interface IDoubleSineHookBinding {
    function manager() external view returns (address);
    function router() external view returns (address);
    function tokenA() external view returns (address);
    function tokenB() external view returns (address);
}
