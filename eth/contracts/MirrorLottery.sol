// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/v4.4.0/contracts/token/ERC20/IERC20.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/v4.4.0/contracts/access/Ownable.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/v4.4.0/contracts/security/ReentrancyGuard.sol";

contract LuckyDraw is Ownable, ReentrancyGuard {
    IERC20 public token;
    address[] public participants;

    uint256 public winningNumber;

    struct Ticket {
        uint256[] mainNumbers;
        uint256 powerballNumber;
    }

    struct Winner {
        address winnerAddress;
        uint256[] matchingNumbers;
    }

    Winner[] public pastWinners;

    mapping(address => Ticket[]) private userTickets;

    function getUserTickets(address user, uint256 index)
        public
        view
        returns (uint256[] memory mainNumbers, uint256 powerballNumber)
    {
        Ticket memory ticket = userTickets[user][index];
        return (ticket.mainNumbers, ticket.powerballNumber);
    }

    mapping(address => uint256) public userContributions;

    // Rate limiting
    uint256 public minTimeBetweenParticipation;
    mapping(address => uint256) public lastParticipation;

    // Management fee and next pool prize percentage
    uint256 public managementFeePercentage;
    uint256 public nextPoolPrizePercentage;

    event WinnersSelected(uint256[] winningCounts, uint256[] divisionPrizes);


    // Add the Package struct
    struct Package {
        uint256 combinations;
        uint256 price;
        bool active;
    }

    // Add the mapping to store packages
    mapping(uint256 => Package) public packages;

    // Add a package count variable
    uint256 public packageCount;

    constructor(
        address _tokenAddress,
        uint256 _minTimeBetweenParticipation,
        uint256 _managementFeePercentage,
        uint256 _nextPoolPrizePercentage
    ) {
        token = IERC20(_tokenAddress);
        minTimeBetweenParticipation = _minTimeBetweenParticipation;
        managementFeePercentage = _managementFeePercentage;
        nextPoolPrizePercentage = _nextPoolPrizePercentage;
    }

    function addPackage(uint256 combinations, uint256 price)
        external
        onlyOwner
    {
        packageCount++;
        packages[packageCount] = Package({
            combinations: combinations,
            price: price,
            active: true
        });
    }

    function updatePackage(
        uint256 packageId,
        uint256 newCombinations,
        uint256 newPrice
    ) external onlyOwner {
        require(packages[packageId].active, "Package not found");
        packages[packageId].combinations = newCombinations;
        packages[packageId].price = newPrice;
    }

    function removePackage(uint256 packageId) external onlyOwner {
        require(packages[packageId].active, "Package not found");
        delete packages[packageId];
    }

    function participate(
        uint256 packageId,
        uint256[][] calldata mainNumbersList,
        uint256[] calldata powerballNumbers
    ) external nonReentrant {
        require(packages[packageId].combinations > 0, "Invalid packageId");
        require(
            mainNumbersList.length == packages[packageId].combinations,
            "Invalid number of combinations for package"
        );
        require(
            mainNumbersList.length == powerballNumbers.length,
            "Mismatch in mainNumbers and powerballNumbers count"
        );

        uint256 totalCost = packages[packageId].price;
        require(
            token.balanceOf(msg.sender) >= totalCost,
            "Insufficient token balance"
        );
        require(
            lastParticipation[msg.sender] + minTimeBetweenParticipation <=
                block.timestamp,
            "Rate limit exceeded"
        );

        // Transfer the entry fee from the user to the contract
        token.transferFrom(msg.sender, address(this), totalCost);

        // Update the user's total contributions
        userContributions[msg.sender] += totalCost;

        // Update the user's tickets
        for (uint256 i = 0; i < mainNumbersList.length; i++) {
            require(
                mainNumbersList[i].length == 5,
                "Ticket must have exactly 5 main numbers"
            );
            Ticket memory ticket;
            ticket.mainNumbers = mainNumbersList[i];
            ticket.powerballNumber = powerballNumbers[i];
            userTickets[msg.sender].push(ticket);
        }

        // Add the user to the participants array if they are not already in it
        bool isParticipant = false;
        for (uint256 i = 0; i < participants.length; i++) {
            if (participants[i] == msg.sender) {
                isParticipant = true;
                break;
            }
        }
        if (!isParticipant) {
            participants.push(msg.sender);
        }

        // Update the user's last participation timestamp
        lastParticipation[msg.sender] = block.timestamp;
    }

    function selectWinner(uint256[] memory mainNumbers, uint256 powerballNumber)
        external
        onlyOwner
    {
        require(
            mainNumbers.length == 5,
            "Winning numbers must have exactly 5 main numbers"
        );

        uint256 poolBalance = token.balanceOf(address(this));
        uint256 prize = (poolBalance * 70) / 100;
        uint256 managementFee = (poolBalance * managementFeePercentage) / 100;

        // Calculate next pool prize if the pool is empty
        uint256 nextPoolPrize = 0;
        if (poolBalance - prize - managementFee == 0) {
            nextPoolPrize = (managementFee * nextPoolPrizePercentage) / 100;
            managementFee -= nextPoolPrize;
        }

        // Calculate prizes for each division
        uint256[] memory divisionPrizes = new uint256[](5);
        divisionPrizes[0] = prize; // Division 1: 5 main numbers + powerball
        divisionPrizes[1] = (poolBalance * 10) / 100; // Division 2: 5 main numbers
        divisionPrizes[2] = (poolBalance * 5) / 100; // Division 3: 4 main numbers + powerball
        divisionPrizes[3] = (poolBalance * 3) / 100; // Division 4: 4 main numbers
        divisionPrizes[4] = (poolBalance * 2) / 100; // Division 5: 3 main numbers + powerball

        uint256[] memory winningCounts = new uint256[](5);

        // Iterate through all participants and find the winners
        for (uint256 i = 0; i < participants.length; i++) {
            address participant = participants[i];
            Ticket[] memory tickets = userTickets[participant];

            for (uint256 j = 0; j < tickets.length; j++) {
                Ticket memory ticket = tickets[j];
                uint256 matchCount = _compareArrays(
                    ticket.mainNumbers,
                    mainNumbers
                );
                bool powerballMatch = ticket.powerballNumber == powerballNumber;

                uint8 division = _getDivision(matchCount, powerballMatch);

                if (division != 0) {
                    // Distribute the prize based on the division
                    token.transfer(participant, divisionPrizes[division - 1]);
                    winningCounts[division - 1]++;

                    // Record past winner and matching numbers
                    Winner memory newWinner;
                    newWinner.winnerAddress = participant;
                    newWinner.matchingNumbers = ticket.mainNumbers;
                    pastWinners.push(newWinner);
                }
            }
        }

        // Calculate remaining balance
        // uint256 remainingBalance = token.balanceOf(address(this));

        // Transfer the management fee to the owner
        token.transfer(owner(), managementFee);

        // Transfer the next pool prize
        token.transfer(address(this), nextPoolPrize);

        // Reset user contributions
        for (uint256 i = 0; i < participants.length; i++) {
            userContributions[participants[i]] = 0;
        }

        // Clear participants and userTickets
        delete participants;

        emit WinnersSelected(winningCounts, divisionPrizes);
    }

    function _getDivision(uint256 matchCount, bool powerballMatch)
        private
        pure
        returns (uint8)
    {
        if (matchCount == 5 && powerballMatch) {
            return 1;
        } else if (matchCount == 5) {
            return 2;
        } else if (matchCount == 4 && powerballMatch) {
            return 3;
        } else if (matchCount == 4) {
            return 4;
        } else if (matchCount == 3 && powerballMatch) {
            return 5;
        }

        return 0;
    }

    function _compareArrays(uint256[] memory a, uint256[] memory b)
        private
        pure
        returns (uint256)
    {
        uint256 matchCount = 0;

        for (uint256 i = 0; i < a.length; i++) {
            for (uint256 j = 0; j < b.length; j++) {
                if (a[i] == b[j]) {
                    matchCount++;
                    break;
                }
            }
        }

        return matchCount;
    }

    function getPackage(uint256 packageId)
        public
        view
        returns (
            uint256 combinations,
            uint256 price,
            bool active
        )
    {
        Package memory package = packages[packageId];
        return (package.combinations, package.price, package.active);
    }

    function getPastWinner(uint256 index)
        public
        view
        returns (
            address winnerAddress,
            uint256[] memory matchingNumbers
        )
    {
        Winner memory winner = pastWinners[index];
        return (winner.winnerAddress, winner.matchingNumbers);
    }

    function getPastWinnersCount() public view returns (uint256) {
        return pastWinners.length;
    }

    function getParticipantsCount() public view returns (uint256) {
        return participants.length;
    }
    
    function getAllActivePackages()
        public
        view
        returns (uint256[] memory packageIds, Package[] memory activePackages)
    {
        uint256 activePackageCount = 0;

        // Count active packages
        for (uint256 i = 1; i <= packageCount; i++) {
            if (packages[i].active) {
                activePackageCount++;
            }
        }

        packageIds = new uint256[](activePackageCount);
        activePackages = new Package[](activePackageCount);

        uint256 index = 0;
        for (uint256 i = 1; i <= packageCount; i++) {
            if (packages[i].active) {
                packageIds[index] = i;
                activePackages[index] = packages[i];
                index++;
            }
        }

        return (packageIds, activePackages);
    }
}
