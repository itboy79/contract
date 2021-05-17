pragma solidity 0.6.12;

import "./EnumerableSet.sol";
import "@chainlink/contracts/src/v0.6/VRFConsumerBase.sol";
import "@chainlink/contracts/src/v0.6/vendor/SafeMathChainlink.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/GSN/Context.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "@pancakeswap2/pancake-swap-core/contracts/interfaces/IPancakeFactory.sol";
import "@pancakeswap2/pancake-swap-core/contracts/interfaces/IPancakePair.sol";
import "pancakeswap-peripheral/contracts/interfaces/IPancakeRouter01.sol";
import "pancakeswap-peripheral/contracts/interfaces/IPancakeRouter02.sol";
import "./PegSwap.sol";


contract LOTDOG is Context, IERC20, Ownable, VRFConsumerBase {
    using SafeMathChainlink for uint256;
    using Address for address;
    using EnumerableSet for EnumerableSet.AddressSet;

    address public immutable WETH;

    bytes32 internal immutable keyHash;
    uint256 public linkFee;
    address public immutable linkAddress;
    address public immutable linkPegAddress;
    address public immutable pegSwapAddress;
    address public immutable linkPair;

    IPancakeRouter02 public immutable pancakeswapV2Router;
    PegSwap public immutable pegSwapContract;
    address public immutable pancakeswapV2Pair;
    IERC20 public immutable linkPegContract;


    /*
    * Did the last winner receive his rewards. Being 'false' might indicate that
    * the transfer failed.
    */
    bool public raffleWinnerPaid;

    /**
     * Random Number provided by ChainLink Oracle.
     * Used to determine winner of all eligible participants.
     */
    uint256 public raffleRandomResult;

    /**
     * Address that has won the last raffle.
     */
    address payable public raffleWinner;

    /**
     * Interval in which the raffle is conducted.
     * Used to determine raffleNextTime.
     */
    uint256 public raffleInterval = 8 hours;

    /**
     * When does the next raffle start?
     * Set during the last raffle.
     */
    uint256 public raffleNextTime;

    /**
     * When was the last raffle conducted?
     */
    uint256 public raffleLastTime;

    /**
     * Minimum amount of participants to do a raffle.
     * If current participants too small, then they are still eligible
     * to win in the next raffle without another buy.
     */
    uint8 public constant raffleMinParticipants = 5;

    /**
    * Minimum to buy to participate in raffle in BNB.
    */
    uint256 public minRaffleEntryAmountBnb = (5 * 10**16); //0.05BNB

    /**
    * Threshold to determine whether to notify investors on huge buys/sells which enlarge the raffle pot significantly.
    */
    uint256 public raffleThresholdHugeBuySell = (1 * 10**18); // Example: 50 BNB transfer 2% => 1 BNB

    /**
     * Amount of participant sets to save. Mainly used to
     * safely delete participant sets from previous raffles.
     * Needed because of solidity limitations to save gas.
     */
    uint8 private constant raffleMaxParticipantSetIndex = 2;

    /**
    * Slippage for min entry price in BNB. 120 = 20 % slippage.
    */
    uint8 public tokenBnbEntryPriceSlippage = 120;

    /**
    * slippage for link buy
    * 100 = 1%
    * 50 = 2%
    * 25 = 4%
    */
    uint8 public swapLinkSlippageFactor = 25;

    /**
    * Initialize length of set with +1.
    */
    EnumerableSet.AddressSet[raffleMaxParticipantSetIndex + 1]
        private raffleParticipantSets;

    /**
     * Current index used for the participant set.
     * Determines which set of participants are eligible to win.
     * Will be incremented every x hours (and then starts at 0 again when greater than amount of overall sets).
     */
    uint8 public currentRaffleParticipantSetIndex = 0;

    /**
    * Factor to clean up participant sets.
    */
    uint8 public cleanUpFactor = 10;

    /**
     * Max uint8 constant to avoid throwing errors.
     * Used to determine if all raffleSets have been cleared.
     */
    uint8 private constant MAX_INT8 = uint8(-1);

    address[] private _excluded;

    uint256 private constant MAX = ~uint256(0);
    uint256 private _tTotal = 1000000000 * 10**6 * 10**9;
    uint256 private _rTotal = (MAX - (MAX % _tTotal));
    uint256 private _tFeeTotal;


    string private _name;
    string private _symbol;
    uint8 private _decimals = 9;

    /**
    * Bool to lock recursive calls to avoid interfering calls.
    */
    bool inSwapAndLiquify;

    /**
    * Enable/Disable liquidity swap functionality.
    */
    bool public swapAndLiquifyEnabled = true;

    /**
    * Enable/Disable raffle swap functionality.
    */
    bool public swapForRaffleEnabled = true;

    uint256 public _lotteryFee = 2;
    uint256 private _previousLotteryFee = _lotteryFee;

    uint256 public _taxFee = 4;
    uint256 private _previousTaxFee = _taxFee;

    uint256 public _liquidityFee = 4;
    uint256 private _previousLiquidityFee = _liquidityFee;

    /**
    * Token sum for adding to the LP pool
    */
    uint256 public _liquidityBalanceForPeriod = 0;

    /**
    * Winnable sum in next raffle in Tokens.
    * For winnable sum in BNB access address(this).balance
    */
    uint256 public _lotteryBalanceForPeriod = 0;

    /**
    * Amount the last winner has won in BNB.
    */
    uint256 public _lotteryBalanceInBNBForLastPeriod = 0;

    uint256 public _maxTxAmount = 1000000 * 10**6 * 10**9;
    uint256 private numTokensSellToAddToLiquidity = 500000 * 10**6 * 10**9;
    uint256 private numTokensSellForLottery = 500000 * 10**6 * 10**9;

    mapping(address => uint256) private _rOwned;
    mapping(address => uint256) private _tOwned;
    mapping(address => mapping(address => uint256)) private _allowances;
    mapping(address => bool) private _isExcludedFromFee;
    mapping(address => bool) private _isExcluded;

    event RaffleWarning(string message);
    event WinnerPaid(address winnerAddress, uint256 amount);
    event WhaleAlert(uint256 generalAmount, uint256 addedToPot);
    event SwapAndLiquify(
        uint256 tokensSwapped,
        uint256 ethReceived,
        uint256 tokensIntoLiqudity
    );
    event SwapForRaffle(uint256 amount);

    modifier lockTheSwap {
        inSwapAndLiquify = true;
        _;
        inSwapAndLiquify = false;
    }

    // Structs sometimes needed as solidity only allows a certain number of function/return arguments.
    struct RValuesStruct {
        uint256 tAmount;
        uint256 tFee;
        uint256 tLiquidity;
        uint256 tLottery;
        uint256 currentRate;
    }
    struct ValuesStruct {
        uint256 rAmount;
        uint256 rTransferAmount;
        uint256 rFee;
        uint256 rLottery;
        uint256 tTransferAmount;
        uint256 tFee;
        uint256 tLiquidity;
        uint256 tLottery;
    }

    constructor(
        string memory name,
        string memory symbol,
        address routerAddress,
        address vrfCoordinator,
        address link,
        address linkPeg,
        address pegSwap,
        bytes32 _keyHash
    )
        public
        VRFConsumerBase(vrfCoordinator, link)
    {
        linkAddress = link;
        linkPegAddress = linkPeg;
        pegSwapAddress = pegSwap;
        IPancakeRouter02 _pancakeswapV2Router = IPancakeRouter02(routerAddress);
        pegSwapContract = PegSwap(pegSwap);
        linkPegContract = IERC20(linkPeg);
        WETH = _pancakeswapV2Router.WETH();

        linkPair = IPancakeFactory(_pancakeswapV2Router.factory())
            .getPair(linkPeg, _pancakeswapV2Router.WETH());

        // Set initial raffle time.
        raffleNextTime = block.timestamp + raffleInterval;

        keyHash = _keyHash;
        linkFee = 2 * 10**17; // 0.2 LINK for BSC Prod (Varies by network)

        _name = name;
        _symbol = symbol;

        _rOwned[_msgSender()] = _rTotal;

        // Create a Pancake pair for this new token
        pancakeswapV2Pair = IPancakeFactory(_pancakeswapV2Router.factory())
            .createPair(address(this), _pancakeswapV2Router.WETH());

        // set the rest of the contract variables
        pancakeswapV2Router = _pancakeswapV2Router;

        //exclude owner and this contract from fee
        _isExcludedFromFee[owner()] = true;
        _isExcludedFromFee[address(this)] = true;

        emit Transfer(address(0), _msgSender(), _tTotal);
    }

    /**
     * Verify raffle eligibility + Add / Remove address from raffle participants
     */
    function _modifyRaffleEligibility(
        address from,
        address to,
        uint256 amount,
        bool takeFee
    ) private {
        if(takeFee && swapForRaffleEnabled){

            uint256 amountTokenBnbPrice = getBnbPriceOfToken(pancakeswapV2Pair, amount);
            uint256 amountTokenBnbPriceWithSlippage = amountTokenBnbPrice.mul(tokenBnbEntryPriceSlippage).div(100); // 20 % slippage

            if (from == pancakeswapV2Pair && amountTokenBnbPriceWithSlippage >= minRaffleEntryAmountBnb) {
                //verify BUY, then add to current participant list
                addRaffleParticipant(to);
            } else if (to == pancakeswapV2Pair) {
                //verify SELL, then remove from current participant list (if already added)
                removeRaffleParticipant(from);
            }

            startNextRaffleIfExpired();
        }
    }

    /**
     * @dev Remember that only owner can call so be careful when use on contracts generated from other contracts.
     * @param tokenAddress The token contract address
     * @param tokenAmount Number of tokens to be sent
     source: https://github.com/vittominacori/eth-token-recover/blob/master/contracts/TokenRecover.sol
     */
    function recoverERC20(address tokenAddress, uint256 tokenAmount) external onlyOwner() {
        IERC20(tokenAddress).transfer(owner(), tokenAmount);
    }

    // Called on every transaction if takeFee && swapForRaffleEnabled
    function startNextRaffleIfExpired() private {
        if (block.timestamp >= raffleNextTime) {
            scheduleNextRaffle();
            // Only do raffle if at least n address bought min amount
            if (
                raffleParticipantSets[currentRaffleParticipantSetIndex]
                    .length() >= raffleMinParticipants
            ) {
                bool linkExchanged = swapBnbForLink();
                if (linkExchanged) {
                    // Link needed, if no Link there then simply don't do a raffle.
                    bool raffleInitiated = startRaffleProcedure(block.number);
                    if(!raffleInitiated) {
                        emit RaffleWarning("Not enough LINK on contract balance");
                    }
                } else {
                    emit RaffleWarning("Not enough BNB for BNB->LINK swap");
                }
            } else {
                emit RaffleWarning("Not enough participants to start raffle.");
            }
        } else {
            _cleanUpPreviousParticipantSets();
        }
    }

    /**
     * swap BNB -> PegLINK via pancakeswap
     * swap PegLINK -> Link via PegSwap
     * @return true if success
     * false if failed duo to low Bnb balance
     */
    function swapBnbForLink() private
    returns (bool)
    {
        uint256 linkFeePrice = getTokenPriceInBnb(linkPair, linkFee);

        //1 = can't find the LP pair
        if(linkFeePrice == 1){
            emit RaffleWarning("Can't find Link LP Pair");
            return false;
        }

        uint256 linkFeePriceWithSlippage = linkFeePrice.add(linkFeePrice.div(swapLinkSlippageFactor)); // 1% bc. of fees

        if(linkFeePriceWithSlippage < address(this).balance) {
            address[] memory path = new address[](2);
            path[0] = pancakeswapV2Router.WETH();
            path[1] = address(linkPegAddress);

            // make the swap
            pancakeswapV2Router.swapETHForExactTokens{value: linkFeePriceWithSlippage }(
                linkFee,
                path,
                address(this),
                block.timestamp
            );

            // aprove pe pegSwapToeken to pegSwap
            linkPegContract.approve(address(pegSwapAddress), linkFee);

            // Now swap Pegged LINK to actual LINK. Thank you Link marines <3
            pegSwapContract.swap(linkFee, linkPegAddress, linkAddress);

            return true;
        } else {
            return false;
        }
    }

    //Get current price info of LP Pair
    // Input: Bnb amount
    // Output: token amount
    function getBnbPriceOfToken(address pairAddress, uint amount) private view returns(uint)
    {
        if(isContract(pairAddress)){
            IPancakePair pair = IPancakePair(pairAddress);
            (uint Res0, uint Res1,) = pair.getReserves();
            return (amount * Res1) / Res0;
        } else {
            return 1;
        }
    }

    //Get current price info of LP Pair
    // Input: token amount
    // Output: Bnb amount
    function getTokenPriceInBnb(address pairAddress, uint amount) private view returns(uint)
    {
        if(isContract(pairAddress)){
            IPancakePair pair = IPancakePair(pairAddress);
            (uint Res0, uint Res1,) = pair.getReserves();
            return (amount * Res0) / Res1;
        } else {
            return 1;
        }
    }

    /**
    * Evaluates whether address is a contract and exists.
    */
    function isContract(address addr) view private returns (bool) {
        uint size;
        assembly { size := extcodesize(addr) }
        return size > 0;
    }

    /**
     * Start startRaffleProcedure -> requests randomness from the Link Oracle
     */
    function startRaffleProcedure(uint256 userProvidedSeed)
        private
        returns (bool)
    {
        if(LINK.balanceOf(address(this)) >= linkFee) {
            requestRandomness(keyHash, linkFee, userProvidedSeed);
            return true;
        } else {
            return false;
        }
    }

    /**
     * Callback function used by VRF Coordinator
     */
    function fulfillRandomness(bytes32 requestId, uint256 randomness)
        internal
        override
    {
        raffleRandomResult = randomness;
        payWinner();
        nextRaffleParticipantSet();
    }

    function payWinner() private {
        uint256 length =
            raffleParticipantSets[currentRaffleParticipantSetIndex].length();

        // Determine winner (randomResult from ChainLink oracle)
        uint256 winnerIdx = raffleRandomResult.mod(length);
        raffleWinner = payable(raffleParticipantSets[currentRaffleParticipantSetIndex]
            .at(winnerIdx));

        // Actually pay winner
        _lotteryBalanceInBNBForLastPeriod = address(this).balance; // will be more than previous _lotteryBalanceForPeriod bc. of BNB bug from SafeMoon
        _lotteryBalanceForPeriod = 0; // reset winnable sum

        raffleWinnerPaid = raffleWinner.send(_lotteryBalanceInBNBForLastPeriod);
        if (raffleWinnerPaid) {
            emit WinnerPaid(raffleWinner, _lotteryBalanceInBNBForLastPeriod);
        } else {
            emit RaffleWarning("Couldn't pay winner. Send transaction failed.");
        }
    }

    /**
     * Schedule next raffle by setting the time.
     */
    function scheduleNextRaffle() private {
        raffleLastTime = raffleNextTime; // set last raffle time
        raffleNextTime = raffleLastTime + raffleInterval;
    }

    /**
     * Clean up previous participants set. Private call
     */
    function _cleanUpPreviousParticipantSets() private {
        uint8 nextNonEmptySetIndex = getNextNonEmptyParticipantSet();
        if (nextNonEmptySetIndex != MAX_INT8) { // MAX_INT8 -> all sets empty (except current one)
            garbageCollectRaffleParticipants(nextNonEmptySetIndex, cleanUpFactor);
        } // otherwise no non-empty set except current one.
    }

    /**
     * Clean up previous participants set.
     * Duplicated method to be able to manually clear previous participants to ensure fair raffles if needed.
     */
    function cleanUpPreviousParticipantSets() public onlyOwner() {
        _cleanUpPreviousParticipantSets();
    }

    /**
     * Get next expired participant set which is not empty (needs to be cleared.)
     */
    function getNextNonEmptyParticipantSet() private view returns (uint8) {
        uint8 nextNonEmptySetIndex =
            getNextRaffleParticipantSet(currentRaffleParticipantSetIndex);
        uint256 countParticipants;

        while (nextNonEmptySetIndex != currentRaffleParticipantSetIndex) {
            countParticipants = raffleParticipantSets[nextNonEmptySetIndex]
                .length();
            if (countParticipants > 0) {
                return nextNonEmptySetIndex;
            } else {
                // Ensure while condition doesn't loop forever
                nextNonEmptySetIndex = getNextRaffleParticipantSet(
                    nextNonEmptySetIndex
                );
            }
        }
        return MAX_INT8; // all sets empty (except current one)
    }

    /**
     * Get's the next set of participants.
     */
    function getNextRaffleParticipantSet(uint8 startFromIndex) private pure returns (uint8)
    {
        uint8 nextRaffleParticipantSetIndex;
        if (startFromIndex >= raffleMaxParticipantSetIndex) {
            nextRaffleParticipantSetIndex = 0;
        } else {
            nextRaffleParticipantSetIndex = startFromIndex + 1;
        }
        return nextRaffleParticipantSetIndex;
    }

    /**
     * Switches to next raffle participants set.
     */
    function nextRaffleParticipantSet() private returns (uint8) {
        currentRaffleParticipantSetIndex = getNextRaffleParticipantSet(
            currentRaffleParticipantSetIndex
        );
        return currentRaffleParticipantSetIndex;
    }

    function addRaffleParticipant(address wallet) private returns (bool) {
        return
            raffleParticipantSets[currentRaffleParticipantSetIndex].add(wallet);
    }

    function removeRaffleParticipant(address wallet) private returns (bool) {
        return
            raffleParticipantSets[currentRaffleParticipantSetIndex].remove(
                wallet
            );
    }

    /**
    * Does an address participate in the next raffle?
    * @return Bool whether address participates.
    */
    function containsRaffleParticipant(address wallet)
        public
        view
        returns (bool)
    {
        return raffleParticipantSets[currentRaffleParticipantSetIndex].contains(wallet);
    }

    /**
    * Clears previous raffle participant sets.
    * @return Did clean up succeed? Returns false if someone tried to clear current set.
    */
    function garbageCollectRaffleParticipants(uint8 setIndex, uint256 count)
        private
        returns (bool)
    {
        if (setIndex != currentRaffleParticipantSetIndex) {
            return raffleParticipantSets[setIndex].clean(count);
        }
        return false;
    }

    /**
    * Amount of participants in next raffle.
    * @return Length of current participant set.
    */
    function lengthRaffleParticipants() public view returns (uint256) {
        return raffleParticipantSets[currentRaffleParticipantSetIndex].length();
    }

    function name() public view returns (string memory) {
        return _name;
    }

    function symbol() public view returns (string memory) {
        return _symbol;
    }

    function decimals() public view returns (uint8) {
        return _decimals;
    }

    function totalSupply() public view override returns (uint256) {
        return _tTotal;
    }

    function balanceOf(address account) public view override returns (uint256) {
        if (_isExcluded[account]) return _tOwned[account];
        return tokenFromReflection(_rOwned[account]);
    }

    function transfer(address recipient, uint256 amount)
        public
        override
        returns (bool)
    {
        _transfer(_msgSender(), recipient, amount);
        return true;
    }

    function allowance(address owner, address spender)
        public
        view
        override
        returns (uint256)
    {
        return _allowances[owner][spender];
    }

    function approve(address spender, uint256 amount)
        public
        override
        returns (bool)
    {
        _approve(_msgSender(), spender, amount);
        return true;
    }

    function transferFrom(
        address sender,
        address recipient,
        uint256 amount
    ) public override returns (bool) {
        _transfer(sender, recipient, amount);
        _approve(
            sender,
            _msgSender(),
            _allowances[sender][_msgSender()].sub(
                amount /*, "ERC20: transfer amount exceeds allowance"*/
            )
        );
        return true;
    }

    function increaseAllowance(address spender, uint256 addedValue)
        public
        virtual
        returns (bool)
    {
        _approve(
            _msgSender(),
            spender,
            _allowances[_msgSender()][spender].add(addedValue)
        );
        return true;
    }

    function decreaseAllowance(address spender, uint256 subtractedValue)
        public
        virtual
        returns (bool)
    {
        _approve(
            _msgSender(),
            spender,
            _allowances[_msgSender()][spender].sub(
                subtractedValue /*, "ERC20: decreased allowance below zero"*/
            )
        );
        return true;
    }

    function isExcludedFromReward(address account) public view returns (bool) {
        return _isExcluded[account];
    }

    function totalFees() public view returns (uint256) {
        return _tFeeTotal;
    }

    function deliver(uint256 tAmount) public {
        address sender = _msgSender();
        require(
            !_isExcluded[sender],
            "Excluded addresses cannot call this function"
        );
        uint256 rAmount = _getValues(tAmount).rAmount;

        _rOwned[sender] = _rOwned[sender].sub(rAmount);
        _rTotal = _rTotal.sub(rAmount);
        _tFeeTotal = _tFeeTotal.add(tAmount);
    }

    function reflectionFromToken(uint256 tAmount, bool deductTransferFee)
        public
        view
        returns (uint256)
    {
        require(tAmount <= _tTotal, "Amount must be less than supply");
        if (!deductTransferFee) {
            return _getValues(tAmount).rAmount;
        } else {
            return _getValues(tAmount).rTransferAmount;
        }
    }

    function tokenFromReflection(uint256 rAmount)
        public
        view
        returns (uint256)
    {
        require(
            rAmount <= _rTotal,
            "Amount must be less than total reflections"
        );
        uint256 currentRate = _getRate();
        return rAmount.div(currentRate);
    }

    function excludeFromReward(address account) public onlyOwner() {
        // require(account != 0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D, 'We can not exclude Pancake router.');
        require(!_isExcluded[account], "Account is already excluded");
        if (_rOwned[account] > 0) {
            _tOwned[account] = tokenFromReflection(_rOwned[account]);
        }
        _isExcluded[account] = true;
        _excluded.push(account);
    }

    function includeInReward(address account) external onlyOwner() {
        require(_isExcluded[account], "Account is already excluded");
        for (uint256 i = 0; i < _excluded.length; i++) {
            if (_excluded[i] == account) {
                _excluded[i] = _excluded[_excluded.length - 1];
                _tOwned[account] = 0;
                _isExcluded[account] = false;
                _excluded.pop();
                break;
            }
        }
    }

    function _transferBothExcluded(
        address sender,
        address recipient,
        uint256 tAmount
    ) private {
        ValuesStruct memory valuesStruct = _getValues(tAmount);
        uint256 rAmount = valuesStruct.rAmount;
        uint256 rTransferAmount = valuesStruct.rTransferAmount;
        uint256 rFee = valuesStruct.rFee;
        uint256 tTransferAmount = valuesStruct.tTransferAmount;
        uint256 tFee = valuesStruct.tFee;
        uint256 tLiquidity = valuesStruct.tLiquidity;
        uint256 tLottery = valuesStruct.tLottery;


        _tOwned[sender] = _tOwned[sender].sub(tAmount);
        _rOwned[sender] = _rOwned[sender].sub(rAmount);
        _tOwned[recipient] = _tOwned[recipient].add(tTransferAmount);
        _rOwned[recipient] = _rOwned[recipient].add(rTransferAmount);
        _takeLiquidity(tLiquidity);
        _reflectFee(rFee, tFee);
        _takeForRaffle(tLottery);
        emit Transfer(sender, recipient, tTransferAmount);
    }

    function excludeFromFee(address account) public onlyOwner {
        _isExcludedFromFee[account] = true;
    }

    function includeInFee(address account) public onlyOwner {
        _isExcludedFromFee[account] = false;
    }

    function setTaxFeePercent(uint256 taxFee) external onlyOwner() {
        _taxFee = taxFee;
    }

    /**
    * Slippage for min entry price in BNB. 120 = 20 % slippage.
    */
    function setTokenBnbEntryPriceSlippage(uint8 _tokenBnbEntryPriceSlippage) external onlyOwner() {
        tokenBnbEntryPriceSlippage = _tokenBnbEntryPriceSlippage;
    }



    function setNumTokensSellToAddToLiquidity(uint256 _numTokensSellToAddToLiquidity) external onlyOwner() {
        numTokensSellToAddToLiquidity = _numTokensSellToAddToLiquidity;
    }

    function setNumTokensSellForLottery(uint256 _numTokensSellForLottery) external onlyOwner() {
        numTokensSellForLottery = _numTokensSellForLottery;
    }

    function setMinRaffleEntryAmount(uint256 _minRaffleEntryAmount) external onlyOwner() {
        minRaffleEntryAmountBnb = _minRaffleEntryAmount;
    }

    function setLotteryFeePercent(uint256 lotteryFee) external onlyOwner() {
        _lotteryFee = lotteryFee;
    }

    function setRaffleNextTime(uint256 _raffleNextTime) external onlyOwner() {
        raffleNextTime = _raffleNextTime;
    }

    function setRaffleThresholdHugeBuySell(uint256 _raffleThresholdHugeBuySell) external onlyOwner() {
        raffleThresholdHugeBuySell = _raffleThresholdHugeBuySell;
    }

    function setLiquidityFeePercent(uint256 liquidityFee) external onlyOwner() {
        _liquidityFee = liquidityFee;
    }


    function setLinkFee(uint256 _linkFee) external onlyOwner() {
        linkFee = _linkFee;
    }

    function setMaxTxPercent(uint256 maxTxPercent) external onlyOwner() {
        _maxTxAmount = _tTotal.mul(maxTxPercent).div(10**2);
    }

    function setSwapLinkSlippageFactor(uint8 _swapLinkSlippageFactor) external onlyOwner() {
        swapLinkSlippageFactor = _swapLinkSlippageFactor;
    }

    function setSwapAndLiquifyEnabled(bool _enabled) public onlyOwner {
        swapAndLiquifyEnabled = _enabled;
    }

    function setSwapForRaffleEnabled(bool _enabled) public onlyOwner {
        swapForRaffleEnabled = _enabled;
    }

    function setRaffleInterval(uint256 _raffleInterval) public onlyOwner {
        raffleInterval = _raffleInterval;
    }

    function setCleanUpFactor(uint8 _cleanUpFactor) public onlyOwner {
        cleanUpFactor = _cleanUpFactor;
    }


    // to recieve ETH from pancakeswapV2Router when swaping
    receive() external payable {}

    function _reflectFee(uint256 rFee, uint256 tFee) private {
        _rTotal = _rTotal.sub(rFee);
        _tFeeTotal = _tFeeTotal.add(tFee);
    }

    function _getValues(uint256 tAmount)
        private
        view
        returns (ValuesStruct memory)
    {
        (uint256 tTransferAmount, uint256 tFee, uint256 tLiquidity, uint256 tLottery) =
            _getTValues(tAmount);

        RValuesStruct memory rValuesStruct = RValuesStruct(tAmount, tFee, tLiquidity, tLottery, _getRate());
        (uint256 rAmount, uint256 rTransferAmount, uint256 rFee, uint256 rLottery) =
            _getRValues(rValuesStruct);

        return ValuesStruct(
            rAmount,
            rTransferAmount,
            rFee,
            rLottery,
            tTransferAmount,
            tFee,
            tLiquidity,
            tLottery
        );
    }

    function _getTValues(uint256 tAmount)
        private
        view
        returns (
            uint256,
            uint256,
            uint256,
            uint256
        )
    {
        uint256 tFee = calculateTaxFee(tAmount);
        uint256 tLiquidity = calculateLiquidityFee(tAmount);
        uint256 tLottery = calculateLotteryFee(tAmount);
        uint256 tTransferAmount = tAmount.sub(tFee).sub(tLiquidity).sub(tLottery);
        return (tTransferAmount, tFee, tLiquidity, tLottery);
    }

    function _getRValues(
       RValuesStruct memory rValuesStruct
    )
        private
        pure
        returns (
            uint256,
            uint256,
            uint256,
            uint256
        )
    {
        uint256 rAmount = rValuesStruct.tAmount.mul(rValuesStruct.currentRate);
        uint256 rFee = rValuesStruct.tFee.mul(rValuesStruct.currentRate);
        uint256 rLiquidity = rValuesStruct.tLiquidity.mul(rValuesStruct.currentRate);
        uint256 rLottery = rValuesStruct.tLottery.mul(rValuesStruct.currentRate);
        uint256 rTransferAmount = rAmount.sub(rFee).sub(rLiquidity);
        return (rAmount, rTransferAmount, rFee, rLottery);
    }

    function _getRate() private view returns (uint256) {
        (uint256 rSupply, uint256 tSupply) = _getCurrentSupply();
        return rSupply.div(tSupply);
    }

    function _getCurrentSupply() private view returns (uint256, uint256) {
        uint256 rSupply = _rTotal;
        uint256 tSupply = _tTotal;
        for (uint256 i = 0; i < _excluded.length; i++) {
            if (
                _rOwned[_excluded[i]] > rSupply ||
                _tOwned[_excluded[i]] > tSupply
            ) return (_rTotal, _tTotal);
            rSupply = rSupply.sub(_rOwned[_excluded[i]]);
            tSupply = tSupply.sub(_tOwned[_excluded[i]]);
        }
        if (rSupply < _rTotal.div(_tTotal)) return (_rTotal, _tTotal);
        return (rSupply, tSupply);
    }

    function _takeLiquidity(uint256 tLiquidity) private {
        _liquidityBalanceForPeriod = _liquidityBalanceForPeriod + tLiquidity; // Save liquidity to overall balance until next raffle.
        uint256 currentRate = _getRate();
        uint256 rLiquidity = tLiquidity.mul(currentRate);
        _rOwned[address(this)] = _rOwned[address(this)].add(rLiquidity);
        if (_isExcluded[address(this)])
            _tOwned[address(this)] = _tOwned[address(this)].add(tLiquidity);
    }

    function _takeForRaffle(uint tLottery) private {
        _lotteryBalanceForPeriod = _lotteryBalanceForPeriod + tLottery; // Save lottery to overall balance until next raffle.

        if (swapForRaffleEnabled && _lotteryFee != 0 && tLottery != 0) {
            uint256 tLotteryInBnb = getTokenPriceInBnb(pancakeswapV2Pair, tLottery);
            if (tLotteryInBnb > raffleThresholdHugeBuySell) {
                // Send event to notify investors about huge raffles, when someone sold/bought a huge amount.
                emit WhaleAlert(getTokenPriceInBnb(pancakeswapV2Pair, _lotteryBalanceForPeriod), tLotteryInBnb);
            }
        }

        uint256 currentRate = _getRate();
        uint256 rLottery = tLottery.mul(currentRate);
        _rOwned[address(this)] = _rOwned[address(this)].add(rLottery);
        if (_isExcluded[address(this)]) {
            _tOwned[address(this)] = _tOwned[address(this)].add(tLottery);
        }
    }

    function calculateTaxFee(uint256 _amount) private view returns (uint256) {
        return _amount.mul(_taxFee).div(10**2);
    }

    function calculateLiquidityFee(uint256 _amount)
        private
        view
        returns (uint256)
    {
        return _amount.mul(_liquidityFee).div(10**2);
    }

    function calculateLotteryFee(uint256 _amount) private view returns (uint256) {
        return _amount.mul(_lotteryFee).div(10**2);
    }

    function removeAllFee() private {
        if (_taxFee == 0 && _liquidityFee == 0 && _lotteryFee == 0) return;

        _previousTaxFee = _taxFee;
        _previousLiquidityFee = _liquidityFee;
        _previousLotteryFee = _lotteryFee;

        _taxFee = 0;
        _liquidityFee = 0;
        _lotteryFee = 0;
    }

    function restoreAllFee() private {
        _taxFee = _previousTaxFee;
        _lotteryFee = _previousLotteryFee;
        _liquidityFee = _previousLiquidityFee;
    }

    function isExcludedFromFee(address account) public view returns (bool) {
        return _isExcludedFromFee[account];
    }

    function _approve(
        address owner,
        address spender,
        uint256 amount
    ) private {
        require(owner != address(0), "ERC20: approve from the zero address");
        require(spender != address(0), "ERC20: approve to the zero address");

        _allowances[owner][spender] = amount;
        emit Approval(owner, spender, amount);
    }

    function _transfer(
        address from,
        address to,
        uint256 amount
    ) private {
        require(from != address(0), "ERC20: transfer from the zero address");
        require(to != address(0), "ERC20: transfer to the zero address");
        require(amount > 0, "Transfer amount must be greater than zero");
        if (
            (from != owner() && to != owner()) &&
            (!_isExcludedFromFee[from] && !_isExcludedFromFee[to])
        )
            require(
                amount <= _maxTxAmount,
                "Transfer amount exceeds the maxTxAmount."
            );

        // is the token balance of this contract address over the min number of
        // tokens that we need to initiate a swap + liquidity lock?
        // also, don't get caught in a circular liquidity event.
        // also, don't swap & liquify if sender is Pancake pair.
        uint256 contractTokenBalance = balanceOf(address(this));


        if (contractTokenBalance >= _maxTxAmount) {
            contractTokenBalance = _maxTxAmount;
        }

        bool LiquidityOverMinTokenBalance = _liquidityBalanceForPeriod >= numTokensSellToAddToLiquidity;
        bool LotteryOverMinTokenBalance = _lotteryBalanceForPeriod >= numTokensSellForLottery;
        bool takeFee = true;

        //if any account belongs to _isExcludedFromFee account then remove the fee
        if (_isExcludedFromFee[from] || _isExcludedFromFee[to]) {
            takeFee = false;
        }

    if (
            LiquidityOverMinTokenBalance &&
            !inSwapAndLiquify &&
            from != pancakeswapV2Pair && //Non buy tx (sell or transfer)
            swapAndLiquifyEnabled &&
            takeFee

        ) {
            //add liquidity
            swapAndLiquify(numTokensSellToAddToLiquidity);

            // LiquidityBalance always larger because of outer if condition
            _liquidityBalanceForPeriod = _liquidityBalanceForPeriod.sub(numTokensSellToAddToLiquidity);

        } else if (
            LotteryOverMinTokenBalance &&
            !inSwapAndLiquify &&
            from != pancakeswapV2Pair && //Non buy tx (sell or transfer)
            swapForRaffleEnabled &&
            takeFee
        ) {
            // add to raffle pot
            _swapForRaffle(numTokensSellForLottery);
            _lotteryBalanceForPeriod = _lotteryBalanceForPeriod.sub(numTokensSellForLottery);
        }

        _modifyRaffleEligibility(from, to, amount, takeFee);

        //transfer amount, it will take tax, burn, liquidity fee
        _tokenTransfer(from, to, amount, takeFee);
    }

    function swapAndLiquify(uint256 contractTokenBalance) private lockTheSwap {
        // split the contract balance into halves
        uint256 half = contractTokenBalance.div(2); //ETH
        uint256 otherHalf = contractTokenBalance.sub(half); //BNB

        // capture the contract's current ETH balance.
        // this is so that we can capture exactly the amount of ETH that the
        // swap creates, and not make the liquidity event include any ETH that
        // has been manually sent to the contract
        uint256 initialBalance = address(this).balance;

        // swap tokens for ETH
        swapTokensForEth(half); // <- this breaks the ETH -> HATE swap when swap+liquify is triggered

        // how much ETH did we just swap into?
        uint256 newBalance = address(this).balance.sub(initialBalance);

        // add liquidity to Pancake
        addLiquidity(otherHalf, newBalance);

        emit SwapAndLiquify(half, newBalance, otherHalf);
    }

    function _swapForRaffle(uint256 amount) private lockTheSwap {
        swapTokensForEth(amount);
        emit SwapForRaffle(amount);
    }

    function swapTokensForEth(uint256 tokenAmount) private {
        // generate the Pancake pair path of token -> weth
        address[] memory path = new address[](2);
        path[0] = address(this);
        path[1] = pancakeswapV2Router.WETH();

        _approve(address(this), address(pancakeswapV2Router), tokenAmount);

        // make the swap
        pancakeswapV2Router.swapExactTokensForETHSupportingFeeOnTransferTokens(
            tokenAmount,
            0, // accept any amount of ETH
            path,
            address(this),
            block.timestamp
        );
    }

    function addLiquidity(uint256 tokenAmount, uint256 ethAmount) private {
        // approve token transfer to cover all possible scenarios
        _approve(address(this), address(pancakeswapV2Router), tokenAmount);

        // add the liquidity
        pancakeswapV2Router.addLiquidityETH{value: ethAmount}(
            address(this),
            tokenAmount,
            0, // slippage is unavoidable
            0, // slippage is unavoidable
            owner(),
            block.timestamp
        );
    }

    //this method is responsible for taking all fee, if takeFee is true
    function _tokenTransfer(
        address sender,
        address recipient,
        uint256 amount,
        bool takeFee
    ) private {
        if (!takeFee) removeAllFee();

        if (_isExcluded[sender] && !_isExcluded[recipient]) {
            _transferFromExcluded(sender, recipient, amount);
        } else if (!_isExcluded[sender] && _isExcluded[recipient]) {
            _transferToExcluded(sender, recipient, amount);
        } else if (!_isExcluded[sender] && !_isExcluded[recipient]) {
            _transferStandard(sender, recipient, amount);
        } else if (_isExcluded[sender] && _isExcluded[recipient]) {
            _transferBothExcluded(sender, recipient, amount);
        } else {
            _transferStandard(sender, recipient, amount);
        }

        if (!takeFee) restoreAllFee();
    }

    function _transferStandard(
        address sender,
        address recipient,
        uint256 tAmount
    ) private {
        ValuesStruct memory valuesStruct = _getValues(tAmount);
        uint256 rAmount = valuesStruct.rAmount;
        uint256 rTransferAmount = valuesStruct.rTransferAmount;
        uint256 rFee = valuesStruct.rFee;
        // uint256 rLottery = valuesStruct.rLottery;
        uint256 tTransferAmount = valuesStruct.tTransferAmount;
        uint256 tFee = valuesStruct.tFee;
        uint256 tLiquidity = valuesStruct.tLiquidity;
        uint256 tLottery = valuesStruct.tLottery;

        _rOwned[sender] = _rOwned[sender].sub(rAmount);
        _rOwned[recipient] = _rOwned[recipient].add(rTransferAmount);
        _takeLiquidity(tLiquidity);
        _reflectFee(rFee, tFee);
        _takeForRaffle(tLottery);
        emit Transfer(sender, recipient, tTransferAmount);
    }

    function _transferToExcluded(
        address sender,
        address recipient,
        uint256 tAmount
    ) private {
        ValuesStruct memory valuesStruct = _getValues(tAmount);
        uint256 rAmount = valuesStruct.rAmount;
        uint256 rTransferAmount = valuesStruct.rTransferAmount;
        uint256 rFee = valuesStruct.rFee;
        // uint256 rLottery = valuesStruct.rLottery;
        uint256 tTransferAmount = valuesStruct.tTransferAmount;
        uint256 tFee = valuesStruct.tFee;
        uint256 tLiquidity = valuesStruct.tLiquidity;
        uint256 tLottery = valuesStruct.tLottery;

        _rOwned[sender] = _rOwned[sender].sub(rAmount);
        _tOwned[recipient] = _tOwned[recipient].add(tTransferAmount);
        _rOwned[recipient] = _rOwned[recipient].add(rTransferAmount);
        _takeLiquidity(tLiquidity);
        _reflectFee(rFee, tFee);
        _takeForRaffle(tLottery);
        emit Transfer(sender, recipient, tTransferAmount);
    }

    function _transferFromExcluded(
        address sender,
        address recipient,
        uint256 tAmount
    ) private {
        ValuesStruct memory valuesStruct = _getValues(tAmount);
        uint256 rAmount = valuesStruct.rAmount;
        uint256 rTransferAmount = valuesStruct.rTransferAmount;
        uint256 rFee = valuesStruct.rFee;
        // uint256 rLottery = valuesStruct.rLottery;
        uint256 tTransferAmount = valuesStruct.tTransferAmount;
        uint256 tFee = valuesStruct.tFee;
        uint256 tLiquidity = valuesStruct.tLiquidity;
        uint256 tLottery = valuesStruct.tLottery;

        _tOwned[sender] = _tOwned[sender].sub(tAmount);
        _rOwned[sender] = _rOwned[sender].sub(rAmount);
        _rOwned[recipient] = _rOwned[recipient].add(rTransferAmount);
        _takeLiquidity(tLiquidity);
        _reflectFee(rFee, tFee);
        _takeForRaffle(tLottery);
        emit Transfer(sender, recipient, tTransferAmount);
    }
}
