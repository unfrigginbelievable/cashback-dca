pragma solidity ^0.8.0;

import "@solmate/tokens/ERC20.sol";
import "forge-std/console.sol";

contract BridgedERC20 is ERC20 {
    address public gatewayAddress;
    address public l2Gateway;

    constructor(
        string memory _name,
        string memory _symbol,
        uint8 _decimals
    ) ERC20(_name, _symbol, _decimals) {}

    function bridgeMint(address account, uint256 amount) public {}

    function bridgeBurn(address account, uint256 amount) public {}

    function mint(address account, uint256 amount) public {}
}
