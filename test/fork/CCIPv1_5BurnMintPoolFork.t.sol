// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test, Vm} from "forge-std/Test.sol";
import {CCIPLocalSimulatorFork, Register} from "@chainlink/local/src/ccip/CCIPLocalSimulatorFork.sol";
import {BurnMintTokenPool, TokenPool} from "@chainlink/contracts-ccip/contracts/pools/BurnMintTokenPool.sol";
import {IBurnMintERC20} from "@chainlink/contracts/src/v0.8/shared/token/ERC20/IBurnMintERC20.sol";
import {RegistryModuleOwnerCustom} from
    "@chainlink/contracts-ccip/contracts/tokenAdminRegistry/RegistryModuleOwnerCustom.sol";
import {TokenAdminRegistry} from "@chainlink/contracts-ccip/contracts/tokenAdminRegistry/TokenAdminRegistry.sol";
import {RateLimiter} from "@chainlink/contracts-ccip/contracts/libraries/RateLimiter.sol";
import {IRouterClient} from "@chainlink/contracts-ccip/contracts/interfaces/IRouterClient.sol";
import {Client} from "@chainlink/contracts-ccip/contracts/libraries/Client.sol";

import {
    ERC20,
    ERC20Burnable,
    IERC20
} from
    "@chainlink/contracts/src/v0.8/vendor/openzeppelin-solidity/v4.8.3/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {AccessControl} from
    "@chainlink/contracts/src/v0.8/vendor/openzeppelin-solidity/v4.8.3/contracts/access/AccessControl.sol";

contract MockERC20BurnAndMintToken is IBurnMintERC20, ERC20Burnable, AccessControl {
    address internal immutable i_CCIPAdmin;
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant BURNER_ROLE = keccak256("BURNER_ROLE");

    constructor() ERC20("MockERC20BurnAndMintToken", "MTK") {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(MINTER_ROLE, msg.sender);
        _grantRole(BURNER_ROLE, msg.sender);
        i_CCIPAdmin = msg.sender;
    }

    function mint(address account, uint256 amount) public onlyRole(MINTER_ROLE) {
        _mint(account, amount);
    }

    function burn(uint256 amount) public override(IBurnMintERC20, ERC20Burnable) onlyRole(BURNER_ROLE) {
        super.burn(amount);
    }

    function burnFrom(address account, uint256 amount)
        public
        override(IBurnMintERC20, ERC20Burnable)
        onlyRole(BURNER_ROLE)
    {
        super.burnFrom(account, amount);
    }

    function burn(address account, uint256 amount) public virtual override {
        burnFrom(account, amount);
    }

    function getCCIPAdmin() public view returns (address) {
        return i_CCIPAdmin;
    }
}

contract CCIPv1_5BurnMintPoolFork is Test {
    CCIPLocalSimulatorFork public ccipLocalSimulatorFork;
    MockERC20BurnAndMintToken public mockERC20TokenEthSepolia;
    MockERC20BurnAndMintToken public mockERC20TokenAvalancheFuji;
    BurnMintTokenPool public burnMintTokenPoolEthSepolia;
    BurnMintTokenPool public burnMintTokenPoolAvalancheFuji;

    Register.NetworkDetails ethSepoliaNetworkDetails;
    Register.NetworkDetails avalancheFujiNetworkDetails;

    uint256 ethSepoliaFork;
    uint256 avalancheFujiFork;

    address alice;

    function setUp() public {
        alice = makeAddr("alice");

        string memory ETHEREUM_SEPOLIA_RPC_URL = vm.envString("ETHEREUM_SEPOLIA_RPC_URL");
        string memory AVALANCHE_FUJI_RPC_URL = vm.envString("AVALANCHE_FUJI_RPC_URL");
        ethSepoliaFork = vm.createSelectFork(ETHEREUM_SEPOLIA_RPC_URL);
        avalancheFujiFork = vm.createFork(AVALANCHE_FUJI_RPC_URL);

        ccipLocalSimulatorFork = new CCIPLocalSimulatorFork();
        vm.makePersistent(address(ccipLocalSimulatorFork));

        // Step 1) Deploy token on Ethereum Sepolia
        vm.startPrank(alice);
        mockERC20TokenEthSepolia = new MockERC20BurnAndMintToken();
        vm.stopPrank();

        // Step 2) Deploy token on Avalanche Fuji
        vm.selectFork(avalancheFujiFork);

        vm.startPrank(alice);
        mockERC20TokenAvalancheFuji = new MockERC20BurnAndMintToken();
        vm.stopPrank();
    }

    function test_forkSupportNewCCIPToken() public {
        // Step 3) Deploy BurnMintTokenPool on Ethereum Sepolia
        vm.selectFork(ethSepoliaFork);
        ethSepoliaNetworkDetails = ccipLocalSimulatorFork.getNetworkDetails(block.chainid);
        address[] memory allowlist = new address[](0);
        uint8 localTokenDecimals = 18;

        vm.startPrank(alice);
        burnMintTokenPoolEthSepolia = new BurnMintTokenPool(
            IBurnMintERC20(address(mockERC20TokenEthSepolia)),
            localTokenDecimals,
            allowlist,
            ethSepoliaNetworkDetails.rmnProxyAddress,
            ethSepoliaNetworkDetails.routerAddress
        );
        vm.stopPrank();

        // Step 4) Deploy BurnMintTokenPool on Avalanche Fuji
        vm.selectFork(avalancheFujiFork);
        avalancheFujiNetworkDetails = ccipLocalSimulatorFork.getNetworkDetails(block.chainid);

        vm.startPrank(alice);
        burnMintTokenPoolAvalancheFuji = new BurnMintTokenPool(
            IBurnMintERC20(address(mockERC20TokenAvalancheFuji)),
            localTokenDecimals,
            allowlist,
            avalancheFujiNetworkDetails.rmnProxyAddress,
            avalancheFujiNetworkDetails.routerAddress
        );
        vm.stopPrank();

        // Step 5) Grant Mint and Burn roles to BurnMintTokenPool on Ethereum Sepolia
        vm.selectFork(ethSepoliaFork);

        vm.startPrank(alice);
        mockERC20TokenEthSepolia.grantRole(mockERC20TokenEthSepolia.MINTER_ROLE(), address(burnMintTokenPoolEthSepolia));
        mockERC20TokenEthSepolia.grantRole(mockERC20TokenEthSepolia.BURNER_ROLE(), address(burnMintTokenPoolEthSepolia));
        vm.stopPrank();

        // Step 6) Grant Mint and Burn roles to BurnMintTokenPool on Avalanche Fuji
        vm.selectFork(avalancheFujiFork);

        vm.startPrank(alice);
        mockERC20TokenAvalancheFuji.grantRole(
            mockERC20TokenAvalancheFuji.MINTER_ROLE(), address(burnMintTokenPoolAvalancheFuji)
        );
        mockERC20TokenAvalancheFuji.grantRole(
            mockERC20TokenAvalancheFuji.BURNER_ROLE(), address(burnMintTokenPoolAvalancheFuji)
        );
        vm.stopPrank();

        // Step 7) Claim Admin role on Ethereum Sepolia
        vm.selectFork(ethSepoliaFork);

        RegistryModuleOwnerCustom registryModuleOwnerCustomEthSepolia =
            RegistryModuleOwnerCustom(ethSepoliaNetworkDetails.registryModuleOwnerCustomAddress);

        vm.startPrank(alice);
        registryModuleOwnerCustomEthSepolia.registerAdminViaGetCCIPAdmin(address(mockERC20TokenEthSepolia));
        vm.stopPrank();

        // Step 8) Claim Admin role on Avalanche Fuji
        vm.selectFork(avalancheFujiFork);

        RegistryModuleOwnerCustom registryModuleOwnerCustomAvalancheFuji =
            RegistryModuleOwnerCustom(avalancheFujiNetworkDetails.registryModuleOwnerCustomAddress);

        vm.startPrank(alice);
        registryModuleOwnerCustomAvalancheFuji.registerAdminViaGetCCIPAdmin(address(mockERC20TokenAvalancheFuji));
        vm.stopPrank();

        // Step 9) Accept Admin role on Ethereum Sepolia
        vm.selectFork(ethSepoliaFork);

        TokenAdminRegistry tokenAdminRegistryEthSepolia =
            TokenAdminRegistry(ethSepoliaNetworkDetails.tokenAdminRegistryAddress);

        vm.startPrank(alice);
        tokenAdminRegistryEthSepolia.acceptAdminRole(address(mockERC20TokenEthSepolia));
        vm.stopPrank();

        // Step 10) Accept Admin role on Avalanche Fuji
        vm.selectFork(avalancheFujiFork);

        TokenAdminRegistry tokenAdminRegistryAvalancheFuji =
            TokenAdminRegistry(avalancheFujiNetworkDetails.tokenAdminRegistryAddress);

        vm.startPrank(alice);
        tokenAdminRegistryAvalancheFuji.acceptAdminRole(address(mockERC20TokenAvalancheFuji));
        vm.stopPrank();

        // Step 11) Link token to pool on Ethereum Sepolia
        vm.selectFork(ethSepoliaFork);

        vm.startPrank(alice);
        tokenAdminRegistryEthSepolia.setPool(address(mockERC20TokenEthSepolia), address(burnMintTokenPoolEthSepolia));
        vm.stopPrank();

        // Step 12) Link token to pool on Avalanche Fuji
        vm.selectFork(avalancheFujiFork);

        vm.startPrank(alice);
        tokenAdminRegistryAvalancheFuji.setPool(
            address(mockERC20TokenAvalancheFuji), address(burnMintTokenPoolAvalancheFuji)
        );
        vm.stopPrank();

        // Step 13) Configure Token Pool on Ethereum Sepolia
        vm.selectFork(ethSepoliaFork);

        vm.startPrank(alice);
        TokenPool.ChainUpdate[] memory chains = new TokenPool.ChainUpdate[](1);
        bytes[] memory remotePoolAddressesEthSepolia = new bytes[](1);
        remotePoolAddressesEthSepolia[0] = abi.encode(address(burnMintTokenPoolEthSepolia));
        chains[0] = TokenPool.ChainUpdate({
            remoteChainSelector: avalancheFujiNetworkDetails.chainSelector,
            remotePoolAddresses: remotePoolAddressesEthSepolia,
            remoteTokenAddress: abi.encode(address(mockERC20TokenAvalancheFuji)),
            outboundRateLimiterConfig: RateLimiter.Config({isEnabled: true, capacity: 100_000, rate: 167}),
            inboundRateLimiterConfig: RateLimiter.Config({isEnabled: true, capacity: 100_000, rate: 167})
        });
        uint64[] memory remoteChainSelectorsToRemove = new uint64[](0);
        burnMintTokenPoolEthSepolia.applyChainUpdates(remoteChainSelectorsToRemove, chains);
        vm.stopPrank();

        // Step 14) Configure Token Pool on Avalanche Fuji
        vm.selectFork(avalancheFujiFork);

        vm.startPrank(alice);
        chains = new TokenPool.ChainUpdate[](1);
        bytes[] memory remotePoolAddressesAvalancheFuji = new bytes[](1);
        remotePoolAddressesAvalancheFuji[0] = abi.encode(address(burnMintTokenPoolEthSepolia));
        chains[0] = TokenPool.ChainUpdate({
            remoteChainSelector: ethSepoliaNetworkDetails.chainSelector,
            remotePoolAddresses: remotePoolAddressesAvalancheFuji,
            remoteTokenAddress: abi.encode(address(mockERC20TokenEthSepolia)),
            outboundRateLimiterConfig: RateLimiter.Config({isEnabled: true, capacity: 100_000, rate: 167}),
            inboundRateLimiterConfig: RateLimiter.Config({isEnabled: true, capacity: 100_000, rate: 167})
        });
        burnMintTokenPoolAvalancheFuji.applyChainUpdates(remoteChainSelectorsToRemove, chains);
        vm.stopPrank();

        // Step 15) Mint tokens on Ethereum Sepolia and transfer them to Avalanche Fuji
        vm.selectFork(ethSepoliaFork);

        address linkSepolia = ethSepoliaNetworkDetails.linkAddress;
        ccipLocalSimulatorFork.requestLinkFromFaucet(address(alice), 20 ether);

        uint256 amountToSend = 100;
        Client.EVMTokenAmount[] memory tokenToSendDetails = new Client.EVMTokenAmount[](1);
        Client.EVMTokenAmount memory tokenAmount =
            Client.EVMTokenAmount({token: address(mockERC20TokenEthSepolia), amount: amountToSend});
        tokenToSendDetails[0] = tokenAmount;

        vm.startPrank(alice);
        mockERC20TokenEthSepolia.mint(address(alice), amountToSend);

        mockERC20TokenEthSepolia.approve(ethSepoliaNetworkDetails.routerAddress, amountToSend);
        IERC20(linkSepolia).approve(ethSepoliaNetworkDetails.routerAddress, 20 ether);

        uint256 balanceOfAliceBeforeEthSepolia = mockERC20TokenEthSepolia.balanceOf(alice);

        IRouterClient routerEthSepolia = IRouterClient(ethSepoliaNetworkDetails.routerAddress);
        routerEthSepolia.ccipSend(
            avalancheFujiNetworkDetails.chainSelector,
            Client.EVM2AnyMessage({
                receiver: abi.encode(address(alice)),
                data: "",
                tokenAmounts: tokenToSendDetails,
                extraArgs: Client._argsToBytes(Client.EVMExtraArgsV1({gasLimit: 0})),
                feeToken: linkSepolia
            })
        );

        uint256 balanceOfAliceAfterEthSepolia = mockERC20TokenEthSepolia.balanceOf(alice);
        vm.stopPrank();

        assertEq(balanceOfAliceAfterEthSepolia, balanceOfAliceBeforeEthSepolia - amountToSend);

        ccipLocalSimulatorFork.switchChainAndRouteMessage(avalancheFujiFork);

        uint256 balanceOfAliceAfterAvalancheFuji = mockERC20TokenAvalancheFuji.balanceOf(alice);
        assertEq(balanceOfAliceAfterAvalancheFuji, amountToSend);
    }
}
