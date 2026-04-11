// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IMarketFactory {
    enum MarketStatus {
        Created,
        Active,
        Resolving,
        Resolved,
        Cancelled
    }

    enum Category {
        Futbol,
        Basquet,
        Esports,
        Otros
    }

    struct MarketData {
        bytes32 questionId;
        bytes32 conditionId;
        address creator;
        string metadataURI;
        uint256 creationDeposit;
        uint256 resolutionTimestamp;
        MarketStatus status;
        Category category;
    }

    event MarketCreated(
        uint256 indexed marketId,
        address indexed creator,
        bytes32 conditionId,
        bytes32 questionId,
        string metadataURI,
        uint256 resolutionTimestamp,
        Category category
    );

    event MarketStatusChanged(uint256 indexed marketId, MarketStatus newStatus);

    event CreationDepositRefunded(uint256 indexed marketId, address indexed creator, uint256 amount);

    event CreationDepositUpdated(uint256 oldDeposit, uint256 newDeposit);

    event MarketCancelled(uint256 indexed marketId, address indexed cancelledBy);

    function createMarket(string calldata metadataURI, uint256 resolutionTimestamp, Category category)
        external
        returns (uint256 marketId);

    function pauseMarketCreation() external;

    function unpauseMarketCreation() external;

    function updateCreationDeposit(uint256 newDeposit) external;

    function getMarket(uint256 marketId) external view returns (MarketData memory);

    function refundCreationDeposit(uint256 marketId) external;

    function updateMarketStatus(uint256 marketId, MarketStatus newStatus) external;

    function cancelMarket(uint256 marketId) external;
}
