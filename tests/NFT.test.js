const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("NFT Contracts", function () {
  let NFTi, NFTm;
  let nfti, nftm;
  let owner, addr1, addr2;
  let adminControl;

  beforeEach(async function () {
    [owner, addr1, addr2] = await ethers.getSigners();

    // Deploy AdminControl first
    const AdminControl = await ethers.getContractFactory("AdminControl");
    adminControl = await AdminControl.deploy();
    await adminControl.deployed();

    // Deploy NFT contracts
    NFTi = await ethers.getContractFactory("NFTi");
    NFTm = await ethers.getContractFactory("NFTm");
    
    nfti = await NFTi.deploy(adminControl.address);
    await nfti.deployed();
    
    nftm = await NFTm.deploy(adminControl.address);
    await nftm.deployed();
  });

  describe("NFTi (Investment NFT)", function () {
    describe("Deployment", function () {
      it("Should set the correct admin control", async function () {
        expect(await nfti.adminControl()).to.equal(adminControl.address);
      });

      it("Should have correct name and symbol", async function () {
        expect(await nfti.name()).to.equal("MLife Investment NFT");
        expect(await nfti.symbol()).to.equal("MLI");
      });
    });

    describe("Minting", function () {
      it("Should allow authorized minter to mint NFT", async function () {
        const tokenId = 1;
        const tokenURI = "https://example.com/token/1";
        
        await expect(nfti.safeMint(addr1.address, tokenId, tokenURI))
          .to.emit(nfti, "Transfer")
          .withArgs(ethers.constants.AddressZero, addr1.address, tokenId);
        
        expect(await nfti.ownerOf(tokenId)).to.equal(addr1.address);
        expect(await nfti.tokenURI(tokenId)).to.equal(tokenURI);
      });

      it("Should not allow unauthorized user to mint", async function () {
        const tokenId = 1;
        const tokenURI = "https://example.com/token/1";
        
        await expect(
          nfti.connect(addr1).safeMint(addr2.address, tokenId, tokenURI)
        ).to.be.revertedWith("AdminControl: caller is not authorized");
      });

      it("Should not mint to zero address", async function () {
        const tokenId = 1;
        const tokenURI = "https://example.com/token/1";
        
        await expect(
          nfti.safeMint(ethers.constants.AddressZero, tokenId, tokenURI)
        ).to.be.revertedWith("ERC721: mint to the zero address");
      });
    });

    describe("Transfer", function () {
      beforeEach(async function () {
        // Mint a token first
        await nfti.safeMint(addr1.address, 1, "https://example.com/token/1");
      });

      it("Should transfer NFT between accounts", async function () {
        await expect(
          nfti.connect(addr1).transferFrom(addr1.address, addr2.address, 1)
        ).to.emit(nfti, "Transfer")
          .withArgs(addr1.address, addr2.address, 1);
        
        expect(await nfti.ownerOf(1)).to.equal(addr2.address);
      });

      it("Should not allow unauthorized transfer", async function () {
        await expect(
          nfti.connect(addr2).transferFrom(addr1.address, addr2.address, 1)
        ).to.be.revertedWith("ERC721: caller is not token owner or approved");
      });
    });

    describe("Approval", function () {
      beforeEach(async function () {
        await nfti.safeMint(addr1.address, 1, "https://example.com/token/1");
      });

      it("Should approve another account", async function () {
        await expect(
          nfti.connect(addr1).approve(addr2.address, 1)
        ).to.emit(nfti, "Approval")
          .withArgs(addr1.address, addr2.address, 1);
        
        expect(await nfti.getApproved(1)).to.equal(addr2.address);
      });

      it("Should allow approved account to transfer", async function () {
        await nfti.connect(addr1).approve(addr2.address, 1);
        
        await expect(
          nfti.connect(addr2).transferFrom(addr1.address, addr2.address, 1)
        ).to.emit(nfti, "Transfer");
      });
    });

    describe("Burning", function () {
      beforeEach(async function () {
        await nfti.safeMint(addr1.address, 1, "https://example.com/token/1");
      });

      it("Should allow owner to burn NFT", async function () {
        await expect(nfti.connect(addr1).burn(1))
          .to.emit(nfti, "Transfer")
          .withArgs(addr1.address, ethers.constants.AddressZero, 1);
        
        await expect(nfti.ownerOf(1)).to.be.revertedWith("ERC721: invalid token ID");
      });

      it("Should not allow non-owner to burn NFT", async function () {
        await expect(
          nfti.connect(addr2).burn(1)
        ).to.be.revertedWith("ERC721: caller is not token owner or approved");
      });
    });
  });

  describe("NFTm (Membership NFT)", function () {
    describe("Deployment", function () {
      it("Should set the correct admin control", async function () {
        expect(await nftm.adminControl()).to.equal(adminControl.address);
      });

      it("Should have correct name and symbol", async function () {
        expect(await nftm.name()).to.equal("MLife Membership NFT");
        expect(await nftm.symbol()).to.equal("MLM");
      });
    });

    describe("Minting", function () {
      it("Should allow authorized minter to mint NFT", async function () {
        const tokenId = 1;
        const tokenURI = "https://example.com/membership/1";
        
        await expect(nftm.safeMint(addr1.address, tokenId, tokenURI))
          .to.emit(nftm, "Transfer")
          .withArgs(ethers.constants.AddressZero, addr1.address, tokenId);
        
        expect(await nftm.ownerOf(tokenId)).to.equal(addr1.address);
      });

      it("Should not allow unauthorized user to mint", async function () {
        const tokenId = 1;
        const tokenURI = "https://example.com/membership/1";
        
        await expect(
          nftm.connect(addr1).safeMint(addr2.address, tokenId, tokenURI)
        ).to.be.revertedWith("AdminControl: caller is not authorized");
      });
    });

    describe("Membership Features", function () {
      beforeEach(async function () {
        await nftm.safeMint(addr1.address, 1, "https://example.com/membership/1");
      });

      it("Should track membership status", async function () {
        expect(await nftm.balanceOf(addr1.address)).to.equal(1);
        expect(await nftm.ownerOf(1)).to.equal(addr1.address);
      });

      it("Should support membership transfers", async function () {
        await expect(
          nftm.connect(addr1).transferFrom(addr1.address, addr2.address, 1)
        ).to.emit(nftm, "Transfer")
          .withArgs(addr1.address, addr2.address, 1);
        
        expect(await nftm.ownerOf(1)).to.equal(addr2.address);
        expect(await nftm.balanceOf(addr1.address)).to.equal(0);
        expect(await nftm.balanceOf(addr2.address)).to.equal(1);
      });
    });

    describe("Batch Operations", function () {
      it("Should support batch minting", async function () {
        const recipients = [addr1.address, addr2.address];
        const tokenIds = [1, 2];
        const tokenURIs = [
          "https://example.com/membership/1",
          "https://example.com/membership/2"
        ];
        
        for (let i = 0; i < recipients.length; i++) {
          await expect(
            nftm.safeMint(recipients[i], tokenIds[i], tokenURIs[i])
          ).to.emit(nftm, "Transfer");
        }
        
        expect(await nftm.balanceOf(addr1.address)).to.equal(1);
        expect(await nftm.balanceOf(addr2.address)).to.equal(1);
      });
    });
  });

  describe("Common NFT Features", function () {
    beforeEach(async function () {
      await nfti.safeMint(addr1.address, 1, "https://example.com/token/1");
      await nftm.safeMint(addr1.address, 1, "https://example.com/membership/1");
    });

    it("Should support ERC721 interface", async function () {
      const ERC721InterfaceId = "0x80ac58cd";
      expect(await nfti.supportsInterface(ERC721InterfaceId)).to.be.true;
      expect(await nftm.supportsInterface(ERC721InterfaceId)).to.be.true;
    });

    it("Should return correct token count", async function () {
      expect(await nfti.balanceOf(addr1.address)).to.equal(1);
      expect(await nftm.balanceOf(addr1.address)).to.equal(1);
    });

    it("Should handle approval for all", async function () {
      await expect(
        nfti.connect(addr1).setApprovalForAll(addr2.address, true)
      ).to.emit(nfti, "ApprovalForAll")
        .withArgs(addr1.address, addr2.address, true);
      
      expect(await nfti.isApprovedForAll(addr1.address, addr2.address)).to.be.true;
    });
  });
});