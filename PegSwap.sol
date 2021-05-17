/**
 *Submitted for verification at BscScan.com on 2021-03-13
*/

// File: @chainlink/contracts/src/v0.6/Owned.sol

// SPDX-License-Identifier: MIT
pragma solidity 0.6.12;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/GSN/Context.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "@chainlink/contracts/src/v0.6/vendor/SafeMathChainlink.sol";

/**
 * @title The Owned contract
 * @notice A contract with helpers for basic contract ownership.
 */
contract Owned {

    address public owner;
    address private pendingOwner;

    event OwnershipTransferRequested(
        address indexed from,
        address indexed to
    );
    event OwnershipTransferred(
        address indexed from,
        address indexed to
    );

    constructor() public {
        owner = msg.sender;
    }

    /**
     * @dev Allows an owner to begin transferring ownership to a new address,
     * pending.
     */
    function transferOwnership(address _to)
    external
    onlyOwner()
    {
        pendingOwner = _to;

        emit OwnershipTransferRequested(owner, _to);
    }

    /**
     * @dev Allows an ownership transfer to be completed by the recipient.
     */
    function acceptOwnership()
    external
    {
        require(msg.sender == pendingOwner, "Must be proposed owner");

        address oldOwner = owner;
        owner = msg.sender;
        pendingOwner = address(0);

        emit OwnershipTransferred(oldOwner, msg.sender);
    }

    /**
     * @dev Reverts if called by anyone other than the contract owner.
     */
    modifier onlyOwner() {
        require(msg.sender == owner, "Only callable by owner");
        _;
    }

}

pragma solidity >=0.6.0 <0.8.0;

/**
 * @dev Contract module that helps prevent reentrant calls to a function.
 *
 * Inheriting from `ReentrancyGuard` will make the {nonReentrant} modifier
 * available, which can be applied to functions to make sure there are no nested
 * (reentrant) calls to them.
 *
 * Note that because there is a single `nonReentrant` guard, functions marked as
 * `nonReentrant` may not call one another. This can be worked around by making
 * those functions `private`, and then adding `external` `nonReentrant` entry
 * points to them.
 *
 * TIP: If you would like to learn more about reentrancy and alternative ways
 * to protect against it, check out our blog post
 * https://blog.openzeppelin.com/reentrancy-after-istanbul/[Reentrancy After Istanbul].
 */
abstract contract ReentrancyGuard {
    // Booleans are more expensive than uint256 or any type that takes up a full
    // word because each write operation emits an extra SLOAD to first read the
    // slot's contents, replace the bits taken up by the boolean, and then write
    // back. This is the compiler's defense against contract upgrades and
    // pointer aliasing, and it cannot be disabled.

    // The values being non-zero value makes deployment a bit more expensive,
    // but in exchange the refund on every call to nonReentrant will be lower in
    // amount. Since refunds are capped to a percentage of the total
    // transaction's gas, it is best to keep them low in cases like this one, to
    // increase the likelihood of the full refund coming into effect.
    uint256 private constant _NOT_ENTERED = 1;
    uint256 private constant _ENTERED = 2;

    uint256 private _status;

    constructor () internal {
        _status = _NOT_ENTERED;
    }

    /**
     * @dev Prevents a contract from calling itself, directly or indirectly.
     * Calling a `nonReentrant` function from another `nonReentrant`
     * function is not supported. It is possible to prevent this from happening
     * by making the `nonReentrant` function external, and make it call a
     * `private` function that does the actual work.
     */
    modifier nonReentrant() {
        // On the first call to nonReentrant, _notEntered will be true
        require(_status != _ENTERED, "ReentrancyGuard: reentrant call");

        // Any calls to nonReentrant after this point will fail
        _status = _ENTERED;

        _;

        // By storing the original value once again, a refund is triggered (see
        // https://eips.ethereum.org/EIPS/eip-2200)
        _status = _NOT_ENTERED;
    }
}

// File: contracts/v0.6/token/ERC677Receiver.sol

pragma solidity ^0.6.0;

abstract contract ERC677Receiver {
    function onTokenTransfer(address _sender, uint _value, bytes memory _data) public virtual;
}

// File: contracts/v0.6/PegSwap.sol

pragma solidity >=0.6.0 <0.8.0;



/**
 * @notice This contract provides a one-to-one swap between pairs of tokens. It
 * is controlled by an owner who manages liquidity pools for all pairs. Most
 * users should only interact with the swap, onTokenTransfer, and
 * getSwappableAmount functions.
 */
contract PegSwap is Owned, ReentrancyGuard {
    using SafeMathChainlink for uint256;

    event LiquidityUpdated(
        uint256 amount,
        address indexed source,
        address indexed target
    );
    event TokensSwapped(
        uint256 amount,
        address indexed source,
        address indexed target,
        address indexed caller
    );
    event StuckTokensRecovered(
        uint256 amount,
        address indexed target
    );

    mapping(address => mapping(address => uint256)) private s_swappableAmount;

    /**
     * @dev Disallows direct send by setting a default function without the `payable` flag.
     */
    fallback()
    external
    {}

    /**
     * @notice deposits tokens from the target of a swap pair but does not return
     * any. WARNING: Liquidity added through this method is only retrievable by
     * the owner of the contract.
     * @param amount count of liquidity being added
     * @param source the token that can be swapped for what is being deposited
     * @param target the token that can is being deposited for swapping
     */
    function addLiquidity(
        uint256 amount,
        address source,
        address target
    )
    external
    {
        bool allowed = owner == msg.sender || _hasLiquidity(source, target);
        // By only allowing the owner to add a new pair, we reduce the potential of
        // possible attacks mounted by malicious token contracts.
        require(allowed, "only owner can add pairs");

        _addLiquidity(amount, source, target);

        require(ERC20(target).transferFrom(msg.sender, address(this), amount), "transferFrom failed");
    }

    /**
     * @notice withdraws tokens from the target of a swap pair.
     * @dev Only callable by owner
     * @param amount count of liquidity being removed
     * @param source the token that can be swapped for what is being removed
     * @param target the token that can is being withdrawn from swapping
     */
    function removeLiquidity(
        uint256 amount,
        address source,
        address target
    )
    external
    onlyOwner()
    {
        _removeLiquidity(amount, source, target);

        require(ERC20(target).transfer(msg.sender, amount), "transfer failed");
    }

    /**
     * @notice exchanges the source token for target token
     * @param amount count of tokens being swapped
     * @param source the token that is being given
     * @param target the token that is being taken
     */
    function swap(
        uint256 amount,
        address source,
        address target
    )
    external
    nonReentrant()
    {
        _removeLiquidity(amount, source, target);
        _addLiquidity(amount, target, source);

        emit TokensSwapped(amount, source, target, msg.sender);

        require(ERC20(source).transferFrom(msg.sender, address(this), amount), "transferFrom failed");
        require(ERC20(target).transfer(msg.sender, amount), "transfer failed");
    }

    /**
     * @notice send funds that were accidentally transferred back to the owner. This
     * allows rescuing of funds, and poses no additional risk as the owner could
     * already withdraw any funds intended to be swapped. WARNING: If not called
     * correctly this method can throw off the swappable token balances, but that
     * can be recovered from by transferring the discrepancy back to the swap.
     * @dev Only callable by owner
     * @param amount count of tokens being moved
     * @param target the token that is being moved
     */
    function recoverStuckTokens(
        uint256 amount,
        address target
    )
    external
    onlyOwner()
    {
        emit StuckTokensRecovered(amount, target);

        require(ERC20(target).transfer(msg.sender, amount), "transfer failed");
    }

    /**
     * @notice swap tokens in one transaction if the sending token supports ERC677
     * @param sender address that initially initiated the call to the source token
     * @param amount count of tokens sent for the swap
     * @param targetData address of target token encoded as a bytes array
     */
    function onTokenTransfer(
        address sender,
        uint256 amount,
        bytes calldata targetData
    )
    external
    {
        address source = msg.sender;
        address target = abi.decode(targetData, (address));

        _removeLiquidity(amount, source, target);
        _addLiquidity(amount, target, source);

        emit TokensSwapped(amount, source, target, sender);

        require(ERC20(target).transfer(sender, amount), "transfer failed");
    }

    /**
     * @notice returns the amount of tokens for a pair that are available to swap
     * @param source the token that is being given
     * @param target the token that is being taken
     * @return amount count of tokens available to swap
     */
    function getSwappableAmount(
        address source,
        address target
    )
    public
    view
    returns(
        uint256 amount
    )
    {
        return s_swappableAmount[source][target];
    }


    // PRIVATE

    function _addLiquidity(
        uint256 amount,
        address source,
        address target
    )
    private
    {
        uint256 newAmount = getSwappableAmount(source, target).add(amount);
        s_swappableAmount[source][target] = newAmount;

        emit LiquidityUpdated(newAmount, source, target);
    }

    function _removeLiquidity(
        uint256 amount,
        address source,
        address target
    )
    private
    {
        uint256 newAmount = getSwappableAmount(source, target).sub(amount);
        s_swappableAmount[source][target] = newAmount;

        emit LiquidityUpdated(newAmount, source, target);
    }

    function _hasLiquidity(
        address source,
        address target
    )
    private
    returns (
        bool hasLiquidity
    )
    {
        if (getSwappableAmount(source, target) > 0) return true;
        if (getSwappableAmount(target, source) > 0) return true;
        return false;
    }

}
