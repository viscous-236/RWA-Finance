//SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {FunctionsClient} from "@chainlink/contracts/src/v0.8/functions/v1_3_0/FunctionsClient.sol";
import {FunctionsRequest} from "@chainlink/contracts/src/v0.8/functions/v1_3_0/FunctionsClient.sol";
import {InvoiceToken} from "./InvoiceToken.sol";
import {AutomationCompatibleInterface} from "@chainlink/contracts/src/v0.8/automation/AutomationCompatible.sol";


contract Main is FunctionsClient, ReentrancyGuard, AutomationCompatibleInterface {
    using FunctionsRequest for FunctionsRequest.Request;

    error Main__MoreThanZero(uint256 _number);
    error Main__MustBeValidAddress(address _address);
    error Main__MustBeUnique();
    error Main__CallerMustBeSupplier();
    error Main__CallerMustBeInvestor();
    error Main__DueDateMustBeInFuture(uint256 _dueDate, uint256 currentTime);
    error Main__InvoiceTokenNotFound();
    error Main__InvoiceMustBeApproved();
    error Main__TokensBuyingFails();
    error Main__RoleAlereadyChosen();
    error Main__InvoiceStatusMustBeVerificationInProgress();
    error Main__InvoiceStatusMustBePending();
    error Main__InvoiceStatusMustBeApproved();
    error Main__InvoiceNotExist();
    error Main__MustBeBuyerOfTheInvoice();
    error Main__CallerMustBeBuyer();
    error Main__InsufficientPayment();
    error Main__InvoiceAlreadyPaid();
    error Main__PaymentDistributionFailed();
    error Main__OnlyAuthorizedUpkeepers();
    error Main__OnlyOwner();
    error Main__ErrorInBurningTokens();
    error Main__InvoiceTokenAlreadyGenerated();

    uint64 private s_subscriptionId;
    bytes32 private s_donId;
    uint32 private s_gasLimit = 300000;
    uint256 public distributionCounter;
    uint256 public nextDistributionToProcess;
    uint256 public totalPendingDistributions;
    uint256 private constant GRACEPERIOD = 2 days;
    uint256 private constant MAX_PENDING_DISTRIBUTIONS = 10;
    uint256 public constant ONE_DOLLAR = 1e18;
    uint256[] public arrayOfInoviceIds;

    address public immutable owner;


    
    string private constant VERIFICATION_SOURCE = 
        "const invoiceId = args[0];"
        "console.log('Verifying invoice:', invoiceId);"
        "const response = await Functions.makeHttpRequest({"
            "url: 'https://invoice-server-pyo5.vercel.app/api/verify-invoice',"
            "method: 'POST',"
            "headers: {'Content-Type': 'application/json'},"
            "data: JSON.stringify({invoiceId: invoiceId}),"
            "timeout: 9000"
        "});"
        "console.log('Full API Response:', JSON.stringify(response, null, 2));"
        "if (response.error) {"
            "console.log('Request error:', response.error);"
            "throw new Error('Request failed: ' + response.error);"
        "}"
        "if (!response.status || response.status !== 200) {"
            "console.log('HTTP Status:', response.status);"
            "throw new Error('API returned status: ' + response.status);"
        "}"
        "const data = response.data;"
        "console.log('Response data:', JSON.stringify(data, null, 2));"
        "if (!data || typeof data.isValid === 'undefined') {"
            "console.log('Invalid response structure:', data);"
            "throw new Error('Invalid response structure from API');"
        "}"
        "const isValid = data.isValid === true;"
        "console.log('Final isValid result:', isValid);"
        "return Functions.encodeString(isValid ? '1' : '0');";

    enum UserRole {
        Supplier,
        Buyer,
        Investor
    }

    enum InvoiceStatus {
        Pending,
        VerificationInProgress,
        Approved,
        Rejected,
        Paid
    }

    struct Invoice {
        uint256 id;
        address supplier;
        address buyer;
        uint256 amount;
        address[] investors;
        InvoiceStatus status;
        uint256 dueDate;
        uint256 totalInvestment;
        bool isPaid;
    }

    struct PaymentDistribution {
        uint256 invoiceId;
        uint256 totalPayment;
        bool processed;
        uint256 timestamp;
    }

    mapping(uint256 id => mapping(address investor => uint256 amountOfTokensPurchased)) public
        amountOfTokensPurchasedByInvestor;
    mapping(uint256 id => Invoice invoice) public invoices;
    mapping(uint256 id => bool) public IdExists;
    mapping(address user => UserRole role) public userRole;
    mapping(uint256 id => address token) public invoiceToken;
    mapping(address => bool) public hasChosenRole;
    mapping(bytes32 => uint256) public pendingRequests;
    mapping(address buyer => uint256[] invoiceIds) public buyerInvoices;
    mapping(address supplier => uint256[] invoicesIds) public supplierInvoices;
    mapping(uint256 id => PaymentDistribution distribution) public pendingDistributions;
    mapping(uint256 => bool) public isTokenGenerated;

    event ContractFunded(address indexed sender, uint256 amount);
    event InvoiceCreated(
        uint256 indexed id, address indexed supplier, address indexed buyer, uint256 amount, uint256 dueDate
    );
    event SuccessfulTokenPurchase(uint256 indexed invoiceId, address indexed buyer, uint256 amount);
    event InvoiceVerificationRequested(uint256 indexed invoiceId, bytes32 requestId);
    event InvoiceVerified(uint256 indexed invoiceId, bool isValid);
    event PaymentReceived(uint256 indexed invoiceId, address indexed buyer, uint256 amount);
    event InvoicePaid(uint256 indexed invoiceId, uint256 amount);
    event PaymentDistributed(uint256 indexed invoiceId, address indexed receiver, uint256 amount);
    event PaymentToSupplier(uint256 indexed invoiceId, address indexed supplier, uint256 amount);
    event InvoiceTokenCreated(uint256 indexed invoiceId, address indexed tokenAddress);
    event UpkeeperAuthorized(address indexed upkeeper);
    event UpkeeperRevoked(address indexed upkeeper);
    event AllTokensBurned(uint256 indexed invoiceId, address[] investors);
    event InvoiceVerificationError(uint256 indexed invoiceId, string error);
    event UnknownRequestReceived(bytes32 indexed requestId);
    event InvoiceStateError(uint256 indexed invoiceId, uint8 currentStatus);
    event InvoiceTokenRequestCreated(uint256 indexed invoiceId, address indexed tokenAddress);


    modifier MoreThanZero(uint256 _number) {
        if (_number <= 0) {
            revert Main__MoreThanZero(_number);
        }
        _;
    }

    modifier ValidAddress(address _address) {
        if (_address == address(0)) {
            revert Main__MustBeValidAddress(_address);
        }
        _;
    }



    constructor(address router, uint64 subscriptionId, bytes32 donId) FunctionsClient(router) {
        s_subscriptionId = subscriptionId;
        s_donId = donId;
        owner = msg.sender;
        nextDistributionToProcess = 1; 
    }

    /*//////////////////////////////////////////////////////////////
                       EXTERNAL_PUBLIC_FUNCTIONS
    //////////////////////////////////////////////////////////////*/
    receive() external payable {
        emit ContractFunded(msg.sender, msg.value);
    }


    function chooseRole(UserRole _role) external {
        if (hasChosenRole[msg.sender]) revert Main__RoleAlereadyChosen();
        userRole[msg.sender] = _role;
        hasChosenRole[msg.sender] = true;
    }

    function createInvoice(uint256 _id, address _buyer, uint256 _amount, uint256 _dueDate)
        external
        MoreThanZero(_id)
        MoreThanZero(_amount)
        ValidAddress(_buyer)
    {
        if (IdExists[_id]) revert Main__MustBeUnique();
        if (userRole[msg.sender] != UserRole.Supplier) revert Main__CallerMustBeSupplier();
        if (block.timestamp >= _dueDate) revert Main__DueDateMustBeInFuture(_dueDate, block.timestamp);

        IdExists[_id] = true;
        invoices[_id] = Invoice({
            id: _id,
            supplier: msg.sender,
            buyer: _buyer,
            amount: _amount,
            investors: new address[](0),
            status: InvoiceStatus.Pending,
            dueDate: _dueDate,
            totalInvestment: 0,
            isPaid: false
        });
        buyerInvoices[_buyer].push(_id);
        supplierInvoices[msg.sender].push(_id);
        arrayOfInoviceIds.push(_id);

        emit InvoiceCreated(_id, msg.sender, _buyer, _amount, _dueDate);
    }

    function verifyInvoice(uint256 invoiceId) external {
        if (userRole[msg.sender] != UserRole.Supplier) revert Main__CallerMustBeSupplier();
        if (invoices[invoiceId].status != InvoiceStatus.Pending) revert Main__InvoiceStatusMustBePending();

        invoices[invoiceId].status = InvoiceStatus.VerificationInProgress;

        FunctionsRequest.Request memory req;
        req.initializeRequestForInlineJavaScript(VERIFICATION_SOURCE);

        string[] memory args = new string[](1);
        args[0] = _uint2str(invoiceId);
        req.setArgs(args);

        bytes32 requestId = _sendRequest(req.encodeCBOR(), s_subscriptionId, s_gasLimit, s_donId);

        pendingRequests[requestId] = invoiceId;
        emit InvoiceVerificationRequested(invoiceId, requestId);
    }


    function _fulfillRequest(bytes32 requestId, bytes memory response, bytes memory error) internal override {
        uint256 invoiceId = pendingRequests[requestId];

        // Validate request exists
        if (invoiceId == 0) {
            emit UnknownRequestReceived(requestId);
            return;
        }

        // Validate invoice state - use graceful handling instead of revert
        if (invoices[invoiceId].status != InvoiceStatus.VerificationInProgress) {
            emit InvoiceStateError(invoiceId, uint8(invoices[invoiceId].status));
            delete pendingRequests[requestId];
            return;
        }

        // Handle Chainlink errors
        if (error.length > 0) {
            _handleVerificationError(invoiceId, string(error));
            delete pendingRequests[requestId];
            return;
        }

        // Handle successful response
        if (response.length > 0) {
            _handleVerificationSuccess(invoiceId, response);
        } else {
            _handleVerificationError(invoiceId, "Empty response received");
        }

        delete pendingRequests[requestId];
    }

    function tokenGeneration(uint256 invoiceId, uint256 amount) external {
        if (userRole[msg.sender] != UserRole.Supplier) revert Main__CallerMustBeSupplier();
        if (invoices[invoiceId].status != InvoiceStatus.Approved) revert Main__InvoiceMustBeApproved();
        if (isTokenGenerated[invoiceId]) revert Main__InvoiceTokenAlreadyGenerated();

        _generateErc20(invoiceId, amount);
        isTokenGenerated[invoiceId] = true;
        emit InvoiceTokenRequestCreated(invoiceId, invoiceToken[invoiceId]);
    }

    function _handleVerificationError(uint256 invoiceId, string memory errorMsg) internal {
        emit InvoiceVerificationError(invoiceId, errorMsg);
        invoices[invoiceId].status = InvoiceStatus.Rejected;
        emit InvoiceVerified(invoiceId, false);
    }

    function _handleVerificationSuccess(uint256 invoiceId, bytes memory response) internal {
        // Safe string conversion and comparison
        string memory responseStr = string(response);
        bool isValid = keccak256(bytes(responseStr)) == keccak256(bytes("1"));

        invoices[invoiceId].status = isValid ? InvoiceStatus.Approved : InvoiceStatus.Rejected;
        emit InvoiceVerified(invoiceId, isValid);
    }

    function buyTokens(uint256 _id, uint256 _amount) external payable MoreThanZero(_amount) {
        if (userRole[msg.sender] != UserRole.Investor) revert Main__CallerMustBeInvestor();
        if (invoiceToken[_id] == address(0)) revert Main__InvoiceTokenNotFound();
        if (invoices[_id].status != InvoiceStatus.Approved) revert Main__InvoiceMustBeApproved();

        amountOfTokensPurchasedByInvestor[_id][msg.sender] += _amount;
        invoices[_id].totalInvestment += _amount;
        if (amountOfTokensPurchasedByInvestor[_id][msg.sender] == _amount) {
            invoices[_id].investors.push(msg.sender);
        }
        InvoiceToken token = InvoiceToken(invoiceToken[_id]);
        //uint256 tokenPriceInEth = token.getExactCost(_amount);
        bool success = token.buyTokens{value: msg.value}(_amount, msg.sender);
        if (!success) revert Main__TokensBuyingFails();
        emit SuccessfulTokenPurchase(_id, msg.sender, _amount);
    }

     function _getTotalDebtAmount(uint256 _id) public view returns (uint256) {
        uint256 debtAmount = invoices[_id].amount;
        uint256 graceDueTime = invoices[_id].dueDate + GRACEPERIOD;

        if (block.timestamp > graceDueTime) {
            uint256 overdueTime = block.timestamp - graceDueTime;
            uint256 penalty = (debtAmount * 4 / 100) * (overdueTime / 1 days);
            return (debtAmount + penalty);
        }
        return debtAmount;
    }

    function buyerPayment(uint256 _id) external payable {
        if (userRole[msg.sender] != UserRole.Buyer) revert Main__CallerMustBeBuyer();
        if (IdExists[_id] == false) revert Main__InvoiceNotExist();
        if (invoices[_id].buyer != msg.sender) revert Main__MustBeBuyerOfTheInvoice();
        if (invoices[_id].status != InvoiceStatus.Approved) revert Main__InvoiceMustBeApproved();
        if (invoices[_id].status == InvoiceStatus.Paid) revert Main__InvoiceAlreadyPaid();

       // InvoiceToken token = InvoiceToken(invoiceToken[_id]);
        uint256 totalDebtAmountInDollars = _getTotalDebtAmount(_id);
        if (totalDebtAmountInDollars >= 2 * invoices[_id].amount) {
            totalDebtAmountInDollars = 2 * invoices[_id].amount;
        }
       // uint256 totalDebtAmount = token.getExactCost(totalDebtAmountInDollars);

        //if (msg.value < totalDebtAmount) {
           // revert Main__InsufficientPayment();
        //}
        invoices[_id].status = InvoiceStatus.Paid;

        distributionCounter++;
        pendingDistributions[distributionCounter] =
            PaymentDistribution({invoiceId: _id, totalPayment: msg.value, processed: false, timestamp: block.timestamp});
        totalPendingDistributions++;

        emit PaymentReceived(_id, msg.sender, msg.value);
        emit InvoicePaid(_id, msg.value);
    }

    function checkUpkeep(bytes calldata /* checkData */ )
        external
        view
        override
        returns (bool upkeepNeeded, bytes memory performData)
    {
        if (totalPendingDistributions == 0 || nextDistributionToProcess > distributionCounter) {
            return (false, bytes(""));
        }

        uint256[] memory readyDistributions = new uint256[](MAX_PENDING_DISTRIBUTIONS);
        uint256 count = 0;
        uint256 currentId = nextDistributionToProcess == 0 ? 1 : nextDistributionToProcess;

        while (currentId <= distributionCounter && count < MAX_PENDING_DISTRIBUTIONS) {
            PaymentDistribution memory distribution = pendingDistributions[currentId];

            if (!distribution.processed && distribution.timestamp > 0) {
                readyDistributions[count] = currentId;
                count++;
                upkeepNeeded = true;
            }

            currentId++;
        }

        if (upkeepNeeded && count > 0) {
            uint256[] memory finalDistributions = new uint256[](count);
            for (uint256 i = 0; i < count; i++) {
                finalDistributions[i] = readyDistributions[i];
            }
            performData = abi.encode(finalDistributions);
        }
    }

    function performUpkeep(bytes calldata performData) external override nonReentrant {
        uint256[] memory distributionIds = abi.decode(performData, (uint256[]));
        uint256 length = distributionIds.length;
        for (uint256 i = 0; i < length;) {
            uint256 distributionId = distributionIds[i];
            if (!pendingDistributions[distributionId].processed) {
                _processPaymentDistribution(distributionId);
                _burnToken(distributionId);

                if (distributionId == nextDistributionToProcess) {
                    _updateNextDistributionPointer();
                }
            }
            unchecked {
                i++;
            }
        }
    }
    /*//////////////////////////////////////////////////////////////
                       INTERNAL_PRIVATE_FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function _processPaymentDistribution(uint256 _distributionId) internal {
        PaymentDistribution storage distribution = pendingDistributions[_distributionId];
        uint256 invoiceId = distribution.invoiceId;
        uint256 totalPaymentInEth = distribution.totalPayment;

        Invoice storage invoice = invoices[invoiceId];

        if (invoice.investors.length == 0) {
            _sendPayment(invoice.supplier, totalPaymentInEth);
            emit PaymentToSupplier(invoiceId, invoice.supplier, totalPaymentInEth);
        } else {
            uint256 maxSupply = InvoiceToken(invoiceToken[invoiceId]).maxSupply();
            uint256 supplierPaymentInEth = 0;
            uint256 totalInvestorPaymentInEth = 0;

            uint256 investorCount = invoice.investors.length;
            for (uint256 i = 0; i < investorCount;) {
                address investor = invoice.investors[i];
                uint256 investmentAmount = amountOfTokensPurchasedByInvestor[invoiceId][investor];

                if (investmentAmount > 0) {
                    uint256 paymentShareInEth = (totalPaymentInEth * investmentAmount) / maxSupply;
                    _sendPayment(investor, paymentShareInEth);
                    totalInvestorPaymentInEth += paymentShareInEth;
                    emit PaymentDistributed(invoiceId, investor, paymentShareInEth);
                }
                unchecked {
                    i++;
                }
            }

            supplierPaymentInEth = totalPaymentInEth - totalInvestorPaymentInEth;
            if (supplierPaymentInEth > 0) {
                _sendPayment(invoice.supplier, supplierPaymentInEth);
                emit PaymentToSupplier(invoiceId, invoice.supplier, supplierPaymentInEth);
            }
        }

        distribution.processed = true;
        totalPendingDistributions--;
    }

    function _burnToken(uint256 distributionId) internal {
    uint256 invoiceId = pendingDistributions[distributionId].invoiceId; // Fixed typo
    Invoice storage invoice = invoices[invoiceId];

    if (invoice.investors.length > 0) {
        address tokenAddress = invoiceToken[invoiceId];
        if (tokenAddress != address(0)) {
            InvoiceToken token = InvoiceToken(tokenAddress);
            token.burnAllTokens(invoice.investors); // Remove the strict check
        }
    }

    emit AllTokensBurned(invoiceId, invoice.investors);
}

    function _updateNextDistributionPointer() internal {
        while (nextDistributionToProcess <= distributionCounter) {
            if (
                pendingDistributions[nextDistributionToProcess].processed
                    || pendingDistributions[nextDistributionToProcess].timestamp == 0
            ) {
                nextDistributionToProcess++;
            } else {
                break;
            }
        }
    }

    function _sendPayment(address _receiver, uint256 _amount) internal {
        (bool success,) = payable(_receiver).call{value: _amount}("");
        if (!success) revert Main__PaymentDistributionFailed();
    }

    function _generateErc20(uint256 _id, uint256 _amount) internal {
        string memory name = string(abi.encodePacked("InvoiceToken_", _uint2str(_id)));
        string memory symbol = string(abi.encodePacked("IT_", _uint2str(_id)));

        InvoiceToken newInvoiceToken = new InvoiceToken(name, symbol, _amount, invoices[_id].supplier, address(this));

        invoiceToken[_id] = address(newInvoiceToken);
        emit InvoiceTokenCreated(_id, address(newInvoiceToken));
    }

   

    function _uint2str(uint256 _i) internal pure returns (string memory) {
        if (_i == 0) {
            return "0";
        }
        uint256 j = _i;
        uint256 len;
        while (j != 0) {
            len++;
            j /= 10;
        }
        bytes memory bstr = new bytes(len);
        uint256 k = len;
        while (_i != 0) {
            k = k - 1;
            uint8 temp = (48 + uint8(_i - _i / 10 * 10));
            bytes1 b1 = bytes1(temp);
            bstr[k] = b1;
            _i /= 10;
        }
        return string(bstr);
    }

    /*//////////////////////////////////////////////////////////////
                       GETTER_FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function getBuyerInvoiceIds(address _buyer) external view returns (uint256[] memory) {
        return buyerInvoices[_buyer];
    }

    function getSupplierInvoices(address _supplier) external view returns (uint256[] memory) {
        return supplierInvoices[_supplier];
    }

    function getInvoice(uint256 _invoiceId) external view returns (Invoice memory) {
        return invoices[_invoiceId];
    }

    function getAllInvoiceIds() external view returns (uint256[] memory) {
        return arrayOfInoviceIds;
    }

    function getInvoiceStatus(uint256 _invoiceId) external view returns (InvoiceStatus) {
        return invoices[_invoiceId].status;
    }

    function getPriceOfTokenInEth(uint256 _invoiceId) external view returns (uint256) {
        InvoiceToken token = InvoiceToken(invoiceToken[_invoiceId]);
        return token.getExactCost(1e18);
    }

    function getTokenDetails(uint256 _invoiceId)
        external
        view
        returns (
            address tokenAddress,
            string memory name,
            string memory symbol,
            uint256 totalSupply,
            address supplier,
            uint256 remainingCapacity
        )
    {
        InvoiceToken token = InvoiceToken(invoiceToken[_invoiceId]);

        return (
            invoiceToken[_invoiceId],
            token.name(),
            token.symbol(),
            token.totalSupply(),
            token.getSupplier(),
            token.remainingCapacity()
        );
    }

    function getUserRole(address _user) external view returns (UserRole) {
        return userRole[_user];
    }

    function getInvoiceTokenAddress(uint256 _invoiceId) external view returns (address) {
        return invoiceToken[_invoiceId];
    }

    function getInvoiceDetails(uint256 _invoiceId)
        external
        view
        returns (
            uint256 id,
            address supplier,
            address buyer,
            uint256 amount,
            address[] memory investors,
            InvoiceStatus status,
            uint256 dueDate,
            uint256 totalInvestment,
            bool isPaid
        )
    {
        Invoice storage invoice = invoices[_invoiceId];
        return (
            invoice.id,
            invoice.supplier,
            invoice.buyer,
            invoice.amount,
            invoice.investors,
            invoice.status,
            invoice.dueDate,
            invoice.totalInvestment,
            invoice.isPaid
        );
    }

    function getTotalSupply(uint256 _invoiceId) external view returns (uint256) {
        InvoiceToken token = InvoiceToken(invoiceToken[_invoiceId]);
        return token.totalSupply();
    }

    function getMaxSupply(uint256 _invoiceId) external view returns (uint256) {
        InvoiceToken token = InvoiceToken(invoiceToken[_invoiceId]);
        return token.maxSupply();
    }
}