// SPDX-License-Identifier: MIT
// Constellation Agents — mint contract (ERC721, EIP-2981 royalties).
// 10,000 star charts on BNB Chain, earned by agents that complete real tasks.
// Website: https://constellationagents.xyz
// Minting works through an agent: the agent completes the task, claims a
// voucher from the issuer, and mints. Tiers are drawn on-chain at mint.



pragma solidity 0.8.28;


import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/token/common/ERC2981.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

contract ConstellationAgents is ERC721, ERC2981, Ownable {
    using ECDSA for bytes32;

    uint256 public constant MAX_SUPPLY = 10000;
    uint256 public nextTokenId = 1;


    mapping(uint8 => uint256) public tierPrice;


    mapping(uint8 => uint256) public tierSupply;
    mapping(uint8 => uint256) public tierMinted;


    address public issuer;


    mapping(uint256 => bool) public usedNonce;


    mapping(address => bool) public hasFreeMinted;

    string private _baseTokenURI;

    event Minted(address indexed to, uint256 indexed tokenId, uint8 tier, uint256 nonce);
    event IssuerChanged(address indexed oldIssuer, address indexed newIssuer);
    event BaseURIChanged(string newURI);
    event Withdrawn(address indexed owner, uint256 amount);
    event RoyaltyChanged(address indexed receiver, uint96 feeNumerator);
    constructor(address issuer_) ERC721("Constellation Agents", "CAGT") Ownable(msg.sender) {
        require(issuer_ != address(0), "issuer zero");


        _setDefaultRoyalty(msg.sender, 1000);
        issuer = issuer_;
        tierPrice[1] = 0;
        tierPrice[2] = 0.00042 ether;
        tierPrice[3] = 0.00042 ether;
        tierPrice[4] = 0.00042 ether;
        tierPrice[5] = 0.00042 ether;
        tierSupply[1] = 2000;
        tierSupply[2] = 4000;
        tierSupply[3] = 2400;
        tierSupply[4] = 1120;
        tierSupply[5] = 480;
    }


    /// @notice Set the EIP-2981 royalty receiver and fee (max 10%). Only the owner can call this.
    function setRoyalty(address receiver, uint96 feeNumerator) external onlyOwner {
        require(receiver != address(0), "royalty receiver zero");
        require(feeNumerator <= 1000, "royalty too high");
        _setDefaultRoyalty(receiver, feeNumerator);


        emit RoyaltyChanged(receiver, feeNumerator);
    }

    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(ERC721, ERC2981)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }

    /// @notice Set the voucher signer address. Only the owner can call this.
    function setIssuer(address newIssuer) external onlyOwner {
        require(newIssuer != address(0), "issuer zero");
        address old = issuer;
        issuer = newIssuer;
        emit IssuerChanged(old, newIssuer);
    }


    function _update(address to, uint256 tokenId, address auth)
        internal
        override
        returns (address)
    {
        address from = _ownerOf(tokenId);
        if (from != address(0) && to != address(0)) {
            require(
                nextTokenId > MAX_SUPPLY,
                "transfers locked until sold out"
            );
        }
        return super._update(to, tokenId, auth);
    }

    /// @notice Set the base URI for token metadata. Only the owner can call this.
    function setBaseURI(string calldata uri) external onlyOwner {
        _baseTokenURI = uri;
        emit BaseURIChanged(uri);
    }


    function _voucherDigest(address wallet, uint8 tier, uint256 nonce)
        internal
        view
        returns (bytes32)
    {
        return keccak256(abi.encodePacked(wallet, tier, nonce, block.chainid, address(this)));
    }

    function _baseURI() internal view override returns (string memory) {
        return _baseTokenURI;
    }


    /// @notice Mint for free with the tier drawn on-chain at mint. Requires a valid issuer voucher; one free mint per wallet.
    function mintFreeRandom(uint256 nonce, bytes calldata signature)
        external
        payable
    {
        require(!usedNonce[nonce], "nonce used");
        require(!hasFreeMinted[msg.sender], "free mint already used");
        require(msg.value == 0, "free must be zero");
        require(nextTokenId <= MAX_SUPPLY, "sold out");

        bytes32 digest = _voucherDigest(msg.sender, 1, nonce);
        address recovered = MessageHashUtils.toEthSignedMessageHash(digest).recover(signature);
        require(recovered == issuer, "bad voucher");

        uint256 tier = _pickFreeTier(nonce);
        require(tier >= 1 && tier <= 5, "tier out of range");
        usedNonce[nonce] = true;
        hasFreeMinted[msg.sender] = true;
        tierMinted[uint8(tier)]++;
        uint256 tokenId = nextTokenId++;
        _safeMint(msg.sender, tokenId);
        emit Minted(msg.sender, tokenId, uint8(tier), nonce);
    }


    function _pickFreeTier(uint256 nonce) internal view returns (uint256) {
        bytes32 seed = keccak256(
            abi.encodePacked(
                blockhash(block.number - 1),
                block.timestamp,
                msg.sender,
                nonce,
                nextTokenId
            )
        );
        uint256 start = uint256(seed) % 3;
        for (uint256 i = 0; i < 3; i++) {
            uint256 tier = 1 + ((start + i) % 3);
            if (tierMinted[uint8(tier)] < tierSupply[uint8(tier)]) {
                return tier;
            }
        }
        revert("free tiers sold out");
    }


    /// @notice Mint with a paid voucher (flat 0.00042 BNB). The tier is drawn on-chain from Tier 2-5 at mint.
    function mintPaidRandom(uint256 nonce, bytes calldata signature)
        external
        payable
    {
        require(!usedNonce[nonce], "nonce used");
        require(msg.value >= tierPrice[2], "insufficient payment");
        require(nextTokenId <= MAX_SUPPLY, "sold out");

        bytes32 digest = _voucherDigest(msg.sender, 0, nonce);
        address recovered = MessageHashUtils.toEthSignedMessageHash(digest).recover(signature);
        require(recovered == issuer, "bad voucher");

        uint256 tier = _pickPaidTier(nonce);
        require(tier >= 1 && tier <= 5, "tier out of range");
        usedNonce[nonce] = true;
        tierMinted[uint8(tier)]++;
        uint256 tokenId = nextTokenId++;
        _safeMint(msg.sender, tokenId);
        emit Minted(msg.sender, tokenId, uint8(tier), nonce);
    }


    function _pickPaidTier(uint256 nonce) internal view returns (uint256) {
        bytes32 seed = keccak256(
            abi.encodePacked(
                blockhash(block.number - 1),
                block.timestamp,
                msg.sender,
                nonce,
                nextTokenId
            )
        );
        uint256 start = uint256(seed) % 4;
        for (uint256 i = 0; i < 4; i++) {
            uint256 tier = 2 + ((start + i) % 4);
            if (tierMinted[uint8(tier)] < tierSupply[uint8(tier)]) {
                return tier;
            }
        }
        revert("paid tiers sold out");
    }


    /// @notice Mint a referral reward (fixed Tier 2, Tier 3 fallback). Requires a valid issuer voucher; no payment.
    function mintRewardRandom(uint256 nonce, bytes calldata signature)
        external
        payable
    {
        require(!usedNonce[nonce], "nonce used");
        require(msg.value == 0, "reward must be zero");
        require(nextTokenId <= MAX_SUPPLY, "sold out");

        bytes32 digest = _voucherDigest(msg.sender, 6, nonce);
        address recovered = MessageHashUtils.toEthSignedMessageHash(digest).recover(signature);
        require(recovered == issuer, "bad voucher");

        uint256 tier = 2;
        if (tierMinted[2] < tierSupply[2]) {
            tier = 2;
        } else if (tierMinted[3] < tierSupply[3]) {
            tier = 3;
        } else {
            revert("reward tiers sold out");
        }
        usedNonce[nonce] = true;
        tierMinted[uint8(tier)]++;
        uint256 tokenId = nextTokenId++;
        _safeMint(msg.sender, tokenId);
        emit Minted(msg.sender, tokenId, uint8(tier), nonce);
    }


    /// @notice Withdraw the contract balance to the owner. Only the owner can call this.
    function withdraw() external onlyOwner {
        uint256 amount = address(this).balance;
        (bool ok, ) = owner().call{value: amount}("");
        require(ok, "withdraw failed");
        emit Withdrawn(owner(), amount);
    }
}
