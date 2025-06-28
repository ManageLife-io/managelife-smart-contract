const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("AdminControl", function () {
  let AdminControl;
  let adminControl;
  let owner, admin1, admin2, user1, user2;

  beforeEach(async function () {
    [owner, admin1, admin2, user1, user2] = await ethers.getSigners();

    AdminControl = await ethers.getContractFactory("AdminControl");
    adminControl = await AdminControl.deploy();
    await adminControl.deployed();
  });

  describe("Deployment", function () {
    it("Should set the deployer as owner", async function () {
      expect(await adminControl.owner()).to.equal(owner.address);
    });

    it("Should set owner as initial admin", async function () {
      expect(await adminControl.isAdmin(owner.address)).to.be.true;
    });

    it("Should not set non-owner as admin initially", async function () {
      expect(await adminControl.isAdmin(admin1.address)).to.be.false;
    });
  });

  describe("Admin Management", function () {
    describe("Adding Admins", function () {
      it("Should allow owner to add admin", async function () {
        await expect(
          adminControl.addAdmin(admin1.address)
        ).to.emit(adminControl, "AdminAdded")
          .withArgs(admin1.address);
        
        expect(await adminControl.isAdmin(admin1.address)).to.be.true;
      });

      it("Should allow existing admin to add another admin", async function () {
        // Owner adds admin1
        await adminControl.addAdmin(admin1.address);
        
        // admin1 adds admin2
        await expect(
          adminControl.connect(admin1).addAdmin(admin2.address)
        ).to.emit(adminControl, "AdminAdded")
          .withArgs(admin2.address);
        
        expect(await adminControl.isAdmin(admin2.address)).to.be.true;
      });

      it("Should not allow non-admin to add admin", async function () {
        await expect(
          adminControl.connect(user1).addAdmin(admin1.address)
        ).to.be.revertedWith("AdminControl: caller is not an admin");
      });

      it("Should not allow adding zero address as admin", async function () {
        await expect(
          adminControl.addAdmin(ethers.constants.AddressZero)
        ).to.be.revertedWith("AdminControl: cannot add zero address");
      });

      it("Should not allow adding existing admin", async function () {
        await adminControl.addAdmin(admin1.address);
        
        await expect(
          adminControl.addAdmin(admin1.address)
        ).to.be.revertedWith("AdminControl: address is already an admin");
      });
    });

    describe("Removing Admins", function () {
      beforeEach(async function () {
        await adminControl.addAdmin(admin1.address);
        await adminControl.addAdmin(admin2.address);
      });

      it("Should allow owner to remove admin", async function () {
        await expect(
          adminControl.removeAdmin(admin1.address)
        ).to.emit(adminControl, "AdminRemoved")
          .withArgs(admin1.address);
        
        expect(await adminControl.isAdmin(admin1.address)).to.be.false;
      });

      it("Should allow admin to remove another admin", async function () {
        await expect(
          adminControl.connect(admin1).removeAdmin(admin2.address)
        ).to.emit(adminControl, "AdminRemoved")
          .withArgs(admin2.address);
        
        expect(await adminControl.isAdmin(admin2.address)).to.be.false;
      });

      it("Should not allow non-admin to remove admin", async function () {
        await expect(
          adminControl.connect(user1).removeAdmin(admin1.address)
        ).to.be.revertedWith("AdminControl: caller is not an admin");
      });

      it("Should not allow removing non-admin", async function () {
        await expect(
          adminControl.removeAdmin(user1.address)
        ).to.be.revertedWith("AdminControl: address is not an admin");
      });

      it("Should not allow owner to remove themselves if they are the only admin", async function () {
        // Remove all other admins first
        await adminControl.removeAdmin(admin1.address);
        await adminControl.removeAdmin(admin2.address);
        
        await expect(
          adminControl.removeAdmin(owner.address)
        ).to.be.revertedWith("AdminControl: cannot remove the last admin");
      });
    });
  });

  describe("Role Management", function () {
    const MINTER_ROLE = ethers.utils.keccak256(ethers.utils.toUtf8Bytes("MINTER_ROLE"));
    const BURNER_ROLE = ethers.utils.keccak256(ethers.utils.toUtf8Bytes("BURNER_ROLE"));

    beforeEach(async function () {
      await adminControl.addAdmin(admin1.address);
    });

    describe("Granting Roles", function () {
      it("Should allow admin to grant role", async function () {
        await expect(
          adminControl.grantRole(MINTER_ROLE, user1.address)
        ).to.emit(adminControl, "RoleGranted")
          .withArgs(MINTER_ROLE, user1.address, owner.address);
        
        expect(await adminControl.hasRole(MINTER_ROLE, user1.address)).to.be.true;
      });

      it("Should allow admin to grant role to another user", async function () {
        await expect(
          adminControl.connect(admin1).grantRole(BURNER_ROLE, user2.address)
        ).to.emit(adminControl, "RoleGranted")
          .withArgs(BURNER_ROLE, user2.address, admin1.address);
        
        expect(await adminControl.hasRole(BURNER_ROLE, user2.address)).to.be.true;
      });

      it("Should not allow non-admin to grant role", async function () {
        await expect(
          adminControl.connect(user1).grantRole(MINTER_ROLE, user2.address)
        ).to.be.revertedWith("AdminControl: caller is not an admin");
      });
    });

    describe("Revoking Roles", function () {
      beforeEach(async function () {
        await adminControl.grantRole(MINTER_ROLE, user1.address);
        await adminControl.grantRole(BURNER_ROLE, user2.address);
      });

      it("Should allow admin to revoke role", async function () {
        await expect(
          adminControl.revokeRole(MINTER_ROLE, user1.address)
        ).to.emit(adminControl, "RoleRevoked")
          .withArgs(MINTER_ROLE, user1.address, owner.address);
        
        expect(await adminControl.hasRole(MINTER_ROLE, user1.address)).to.be.false;
      });

      it("Should allow admin to revoke role from another user", async function () {
        await expect(
          adminControl.connect(admin1).revokeRole(BURNER_ROLE, user2.address)
        ).to.emit(adminControl, "RoleRevoked")
          .withArgs(BURNER_ROLE, user2.address, admin1.address);
        
        expect(await adminControl.hasRole(BURNER_ROLE, user2.address)).to.be.false;
      });

      it("Should not allow non-admin to revoke role", async function () {
        await expect(
          adminControl.connect(user1).revokeRole(MINTER_ROLE, user2.address)
        ).to.be.revertedWith("AdminControl: caller is not an admin");
      });
    });
  });

  describe("Function Pausing", function () {
    const FUNCTION_SELECTOR = "0x12345678";

    beforeEach(async function () {
      await adminControl.addAdmin(admin1.address);
    });

    describe("Pausing Functions", function () {
      it("Should allow admin to pause function", async function () {
        await expect(
          adminControl.pauseFunction(FUNCTION_SELECTOR)
        ).to.emit(adminControl, "FunctionPaused")
          .withArgs(FUNCTION_SELECTOR);
        
        expect(await adminControl.isFunctionPaused(FUNCTION_SELECTOR)).to.be.true;
      });

      it("Should allow admin to pause function", async function () {
        await expect(
          adminControl.connect(admin1).pauseFunction(FUNCTION_SELECTOR)
        ).to.emit(adminControl, "FunctionPaused")
          .withArgs(FUNCTION_SELECTOR);
        
        expect(await adminControl.isFunctionPaused(FUNCTION_SELECTOR)).to.be.true;
      });

      it("Should not allow non-admin to pause function", async function () {
        await expect(
          adminControl.connect(user1).pauseFunction(FUNCTION_SELECTOR)
        ).to.be.revertedWith("AdminControl: caller is not an admin");
      });

      it("Should not allow pausing already paused function", async function () {
        await adminControl.pauseFunction(FUNCTION_SELECTOR);
        
        await expect(
          adminControl.pauseFunction(FUNCTION_SELECTOR)
        ).to.be.revertedWith("AdminControl: function is already paused");
      });
    });

    describe("Unpausing Functions", function () {
      beforeEach(async function () {
        await adminControl.pauseFunction(FUNCTION_SELECTOR);
      });

      it("Should allow admin to unpause function", async function () {
        await expect(
          adminControl.unpauseFunction(FUNCTION_SELECTOR)
        ).to.emit(adminControl, "FunctionUnpaused")
          .withArgs(FUNCTION_SELECTOR);
        
        expect(await adminControl.isFunctionPaused(FUNCTION_SELECTOR)).to.be.false;
      });

      it("Should allow admin to unpause function", async function () {
        await expect(
          adminControl.connect(admin1).unpauseFunction(FUNCTION_SELECTOR)
        ).to.emit(adminControl, "FunctionUnpaused")
          .withArgs(FUNCTION_SELECTOR);
        
        expect(await adminControl.isFunctionPaused(FUNCTION_SELECTOR)).to.be.false;
      });

      it("Should not allow non-admin to unpause function", async function () {
        await expect(
          adminControl.connect(user1).unpauseFunction(FUNCTION_SELECTOR)
        ).to.be.revertedWith("AdminControl: caller is not an admin");
      });

      it("Should not allow unpausing non-paused function", async function () {
        await adminControl.unpauseFunction(FUNCTION_SELECTOR);
        
        await expect(
          adminControl.unpauseFunction(FUNCTION_SELECTOR)
        ).to.be.revertedWith("AdminControl: function is not paused");
      });
    });
  });

  describe("Emergency Functions", function () {
    beforeEach(async function () {
      await adminControl.addAdmin(admin1.address);
    });

    describe("Emergency Pause", function () {
      it("Should allow admin to trigger emergency pause", async function () {
        await expect(
          adminControl.emergencyPause()
        ).to.emit(adminControl, "EmergencyPause");
        
        expect(await adminControl.isEmergencyPaused()).to.be.true;
      });

      it("Should allow admin to trigger emergency pause", async function () {
        await expect(
          adminControl.connect(admin1).emergencyPause()
        ).to.emit(adminControl, "EmergencyPause");
        
        expect(await adminControl.isEmergencyPaused()).to.be.true;
      });

      it("Should not allow non-admin to trigger emergency pause", async function () {
        await expect(
          adminControl.connect(user1).emergencyPause()
        ).to.be.revertedWith("AdminControl: caller is not an admin");
      });
    });

    describe("Emergency Unpause", function () {
      beforeEach(async function () {
        await adminControl.emergencyPause();
      });

      it("Should allow admin to lift emergency pause", async function () {
        await expect(
          adminControl.emergencyUnpause()
        ).to.emit(adminControl, "EmergencyUnpause");
        
        expect(await adminControl.isEmergencyPaused()).to.be.false;
      });

      it("Should allow admin to lift emergency pause", async function () {
        await expect(
          adminControl.connect(admin1).emergencyUnpause()
        ).to.emit(adminControl, "EmergencyUnpause");
        
        expect(await adminControl.isEmergencyPaused()).to.be.false;
      });

      it("Should not allow non-admin to lift emergency pause", async function () {
        await expect(
          adminControl.connect(user1).emergencyUnpause()
        ).to.be.revertedWith("AdminControl: caller is not an admin");
      });
    });
  });

  describe("Access Control Integration", function () {
    const MINTER_ROLE = ethers.utils.keccak256(ethers.utils.toUtf8Bytes("MINTER_ROLE"));

    beforeEach(async function () {
      await adminControl.addAdmin(admin1.address);
      await adminControl.grantRole(MINTER_ROLE, user1.address);
    });

    it("Should correctly identify authorized users", async function () {
      expect(await adminControl.isAuthorized(owner.address, MINTER_ROLE)).to.be.true; // Admin
      expect(await adminControl.isAuthorized(admin1.address, MINTER_ROLE)).to.be.true; // Admin
      expect(await adminControl.isAuthorized(user1.address, MINTER_ROLE)).to.be.true; // Has role
      expect(await adminControl.isAuthorized(user2.address, MINTER_ROLE)).to.be.false; // No role
    });

    it("Should handle complex authorization scenarios", async function () {
      // Remove admin status but keep role
      await adminControl.removeAdmin(admin1.address);
      await adminControl.grantRole(MINTER_ROLE, admin1.address);
      
      expect(await adminControl.isAuthorized(admin1.address, MINTER_ROLE)).to.be.true;
      
      // Remove role but add back as admin
      await adminControl.revokeRole(MINTER_ROLE, admin1.address);
      await adminControl.addAdmin(admin1.address);
      
      expect(await adminControl.isAuthorized(admin1.address, MINTER_ROLE)).to.be.true;
    });
  });

  describe("View Functions", function () {
    beforeEach(async function () {
      await adminControl.addAdmin(admin1.address);
      await adminControl.addAdmin(admin2.address);
    });

    it("Should return correct admin count", async function () {
      expect(await adminControl.getAdminCount()).to.equal(3); // owner + admin1 + admin2
    });

    it("Should return admin list", async function () {
      const admins = await adminControl.getAdmins();
      expect(admins).to.include(owner.address);
      expect(admins).to.include(admin1.address);
      expect(admins).to.include(admin2.address);
      expect(admins.length).to.equal(3);
    });

    it("Should correctly report admin status", async function () {
      expect(await adminControl.isAdmin(owner.address)).to.be.true;
      expect(await adminControl.isAdmin(admin1.address)).to.be.true;
      expect(await adminControl.isAdmin(user1.address)).to.be.false;
    });
  });
});