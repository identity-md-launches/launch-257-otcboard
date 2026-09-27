// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @dev Plain mintable ERC-20 with configurable decimals for tests.
contract MockERC20 is ERC20 {
    uint8 private immutable _decimals;

    constructor(string memory name_, string memory symbol_, uint8 decimals_) ERC20(name_, symbol_) {
        _decimals = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @dev Burns `feeBps` of every transfer, so the receiver gets less than the amount argument.
contract FeeOnTransferERC20 is ERC20 {
    uint256 public immutable feeBps;

    constructor(uint256 feeBps_) ERC20("Fee Token", "FEE") {
        feeBps = feeBps_;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0) && to != address(0)) {
            uint256 fee = (value * feeBps) / 10_000;
            if (fee > 0) {
                super._update(from, address(0), fee);
                value -= fee;
            }
        }
        super._update(from, to, value);
    }
}

/// @dev decimals() reverts.
contract RevertingDecimalsToken is ERC20 {
    constructor() ERC20("Bad", "BAD") {}

    function decimals() public pure override returns (uint8) {
        revert("no decimals");
    }
}

/// @dev decimals() returns more than the supported maximum.
contract HugeDecimalsToken is ERC20 {
    constructor() ERC20("Huge", "HUGE") {}

    function decimals() public pure override returns (uint8) {
        return 31;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @dev Has no decimals() function at all.
contract NoDecimalsToken {
    mapping(address => uint256) public balanceOf;

    function transferFrom(address, address, uint256) external pure returns (bool) {
        return true;
    }
}

/// @dev transferFrom always succeeds but moves nothing, so the balance delta is zero.
contract NoOpTransferToken {
    function decimals() external pure returns (uint8) {
        return 18;
    }

    function balanceOf(address) external pure returns (uint256) {
        return 0;
    }

    function transferFrom(address, address, uint256) external pure returns (bool) {
        return true;
    }
}

/// @dev transferFrom returns false so SafeERC20 must revert.
contract FalseReturnToken {
    function decimals() external pure returns (uint8) {
        return 18;
    }

    function balanceOf(address) external pure returns (uint256) {
        return 0;
    }

    function transferFrom(address, address, uint256) external pure returns (bool) {
        return false;
    }
}

interface IHookReceiver {
    function onTokenTransfer(address from, uint256 amount) external;
}

/// @dev ERC-20 that calls a hook on the receiver of every transfer, like ERC-777 / ERC-1363.
///      Used to attempt reentrancy from inside fill and cancel.
contract CallbackERC20 is ERC20 {
    mapping(address => bool) public hooked;

    constructor() ERC20("Callback", "CB") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setHook(address account, bool enabled) external {
        hooked[account] = enabled;
    }

    function _update(address from, address to, uint256 value) internal override {
        super._update(from, to, value);
        if (hooked[to]) {
            IHookReceiver(to).onTokenTransfer(from, value);
        }
    }
}
