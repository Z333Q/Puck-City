// SPDX-License-Identifier: MIT
pragma solidity ^0.8.11;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import "https://github.com/Immutable-X/imx-contracts/blob/master/contracts/ERC20.sol";
import "https://github.com/maticnetwork/pos-portal/contracts/root/RootChainManager.sol";
import "https://github.com/kaleido-io/ethconnect/blob/main/contracts/IOracle.sol";

contract PuckCity is ERC20, ERC1155, Ownable, Pausable {
    uint256 constant public TEAM_COUNT = 32;
    uint256 constant public TOKENS_PER_TEAM = 1000;
    uint256 public transactionFee = 5; // 0.5%
    uint256 public globalTreasury;
    mapping(uint256 => uint256) public reserves; // team ID * TOKENS_PER_TEAM + token ID -> reserve
    mapping(uint256 => address) public teamTreasury; // team ID -> treasury address
    mapping(uint256 => mapping(uint256 => GameResult)) public gameResults; // team ID -> round -> game result
    uint256 public lastResultUpdateTimestamp;

    AggregatorV3Interface internal priceFeed;
    IERC20 internal immutableX;
    RootChainManager internal rootChainManager;
    IOracle internal oracle;

    struct GameResult {
        uint256 homeScore;
        uint256 awayScore;
        bool resultSubmitted;
    }

    constructor(address[] memory _teamTreasuryAddresses, string memory _uri, address _priceFeedAddress, address _immutableXAddress, address _rootChainManagerAddress, address _oracleAddress) ERC20("Puck City", "PUCK") ERC1155(_uri) {
        require(_teamTreasuryAddresses.length == TEAM_COUNT, "Invalid team treasury addresses length");
        for (uint256 i = 0; i < TEAM_COUNT; i++) {
            teamTreasury[i] = _teamTreasuryAddresses[i];
        }

        priceFeed = AggregatorV3Interface(_priceFeedAddress);
        immutableX = IERC20(_immutableXAddress);
        rootChainManager = RootChainManager(_rootChainManagerAddress);
        oracle = IOracle(_oracleAddress);
    }

    function getCurrentPrice() public view returns (uint256) {
        uint256 totalSupply = totalSupply();
        uint256 reserveBalance = getReserveBalance(totalSupply);

        return _calculatePrice(totalSupply + 1, reserveBalance);
    }

    function _calculatePrice(uint256 _supply, uint256 _reserveBalance) internal pure returns (uint256) {
        return (_reserveBalance * (1000000 * (_supply**2))) / (1000000 * (_supply**2) - _supply + 1);
    }

    function purchaseToken(uint256 _amount, uint256 _teamId) public payable whenNotPaused {
        require(_amount > 0 && _amount <= TOKENS_PER_TEAM, "Invalid amount");
        require(_teamId < TEAM_COUNT, "Invalid team ID");

        uint256 totalSupply = totalSupply();
        require(totalSupply < TEAM_COUNT * TOKENS_PER_TEAM, "All tokens have been minted");

        uint256 currentPrice = getCurrentPrice();
uint256 totalPrice = currentPrice * _amount;
require(msg.value >= totalPrice, "Insufficient payment");
    reserves[_teamId * TOKENS_PER_TEAM + (totalSupply % TOKENS_PER_TEAM)] += totalPrice;
    _mint(msg.sender, totalSupply + 1, _amount, "");

    // Transfer 0.5% of the payment to the contract owner
    uint256 transactionFeeAmount = (totalPrice * transactionFee) / 1000;
    payable(owner()).transfer(transactionFeeAmount);

    // Transfer remaining payment to global treasury
    uint256 remainingAmount = totalPrice - transactionFeeAmount;
    globalTreasury += remainingAmount;
}

function claimToken(uint256 _teamId) public {
    uint256 totalSupply = totalSupply();
    require(totalSupply == TEAM_COUNT * TOKENS_PER_TEAM, "Tokens not fully minted yet");
    require(_teamId < TEAM_COUNT, "Invalid team ID");

    uint256 balance = balanceOf(msg.sender, _teamId + 1);
    require(balance > 0, "Balance is zero");

    uint256 reserveBalance = reserves[_teamId * TOKENS_PER_TEAM + balance - 1];
    uint256 currentPrice = getCurrentPrice();
    uint256 value = (reserveBalance * balance * currentPrice) / (TOKENS_PER_TEAM * 1 ether);

    reserves[_teamId * TOKENS_PER_TEAM + balance - 1] = 0;
    _burn(msg.sender, _teamId + 1, balance);

    require(immutableX.transferFrom(msg.sender, address(this), value), "Transfer to global treasury failed");
    globalTreasury += value;
}

function getReserveBalance(uint256 _totalSupply) public view returns (uint256) {
    uint256 balance = address(this).balance - globalTreasury;
    return balance + (priceFeed.latestAnswer() * _totalSupply * 1 ether) / 10**8;
}

function updateResult(uint256 _teamId, uint256 _round, uint256 _homeScore, uint256 _awayScore) public {
    require(msg.sender == address(oracle), "Caller is not the oracle");
    require(_teamId < TEAM_COUNT, "Invalid team ID");
    require(_round > 0, "Invalid round number");
    require(_homeScore <= 100, "Invalid home score");
    require(_awayScore <= 100, "Invalid away score");

    gameResults[_teamId][_round] = GameResult(_homeScore, _awayScore, true);
    lastResultUpdateTimestamp = block.timestamp;
    redistributeFunds(_teamId, _round);
}

function redistributeFunds(uint256 _teamId, uint256 _round) internal {
    uint256 winningReserve = 0;
    uint256 losingReserve = 0;

    for (uint256 i = 0; i < TEAM_COUNT; i++) {
        if (i == _teamId) {
            continue;
        }

        GameResult memory result = gameResults[i][_round];
        if (!result.resultSubmitted) {
            continue;
        }

        uint256 reserve = reserves[i * TOKENS_PER_TEAM + TOKENS_PER_TEAM - 1];
        if (result.homeScore > result.awayScore) {
            winningReserve += reserve;
        } else {
            losingReserve += reserve;
        }
    }

    GameResult memory _result = gameResults[_teamId][_round];
    if (_result.resultSubmitted) {
        uint256 reserve = reserves[_teamId * TOKENS_PER_TEAM + TOKENS_PER_TEAM - 1];
        if (_result.homeScore > _result.awayScore) {
            winningReserve
+= reserve;
} else {
losingReserve += reserve;
}
}
    uint256 totalReserve = winningReserve + losingReserve;
    if (totalReserve == 0) {
        return;
    }

    uint256 winningPercentage = (winningReserve * 100) / totalReserve;
    uint256 losingPercentage = (losingReserve * 100) / totalReserve;

    uint256 winningAmount = (globalTreasury * winningPercentage) / 100;
    uint256 losingAmount = (globalTreasury * losingPercentage) / 100;

    require(immutableX.transfer(teamTreasury[_teamId], winningAmount), "Transfer to winning team treasury failed");
    require(immutableX.transfer(teamTreasury[TEAM_COUNT - _teamId - 1], losingAmount), "Transfer to losing team treasury failed");

    globalTreasury -= winningAmount + losingAmount;
}

function setTransactionFee(uint256 _transactionFee) public onlyOwner {
    require(_transactionFee < 100, "Invalid transaction fee");
    transactionFee = _transactionFee;
}

function withdrawFromTeamTreasury(uint256 _teamId, uint256 _amount) public onlyOwner {
    require(_teamId < TEAM_COUNT, "Invalid team ID");
    require(_amount <= immutableX.balanceOf(teamTreasury[_teamId]), "Insufficient balance in team treasury");
    require(immutableX.transferFrom(teamTreasury[_teamId], owner(), _amount), "Withdrawal from team treasury failed");
}

function setURI(string memory _uri) public onlyOwner {
    _setURI(_uri);
}

function pause() public onlyOwner {
    _pause();
}

function unpause() public onlyOwner {
    _unpause();
}

function migrateERC20ToPolygon(uint256 _amount) public onlyOwner {
    require(immutableX.transfer(address(rootChainManager), _amount), "Transfer to Polygon failed");
    rootChainManager.depositERC20(address(immutableX), msg.sender, _amount);
}

function migrateERC1155ToPolygon(uint256[] memory _ids, uint256[] memory _amounts) public onlyOwner {
    require(immutableX.setApprovalForAll(address(rootChainManager), true), "Failed to approve token transfer");
    _mint(address(this), _ids[0], _amounts[0], "");
    rootChainManager.depositERC1155(address(this), _ids, _amounts);
    _burn(address(this), _ids[0], _amounts[0]);
}

function withdrawFromGlobalTreasury(uint256 _amount) public onlyOwner {
    require(_amount <= immutableX.balanceOf(address(this)), "Insufficient balance in global treasury");
    require(immutableX.transfer(owner(), _amount), "Withdrawal from global treasury failed");
    globalTreasury -= _amount;
}
}
