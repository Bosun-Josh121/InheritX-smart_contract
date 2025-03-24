#[starknet::contract]
pub mod InheritX {
    use core::num::traits::Zero;
    use starknet::storage::{
        Map, StorageMapReadAccess, StorageMapWriteAccess, StoragePointerReadAccess,
        StoragePointerWriteAccess,
    };
    use starknet::{ContractAddress, get_caller_address, get_contract_address};
    use crate::interfaces::IInheritX::{AssetAllocation, IInheritX, InheritancePlan};
    use crate::types::SimpleBeneficiary;

    #[storage]
    struct Storage {
        // Contract addresses for component management
        admin: ContractAddress,
        security_contract: ContractAddress,
        plan_contract: ContractAddress,
        claim_contract: ContractAddress,
        profile_contract: ContractAddress,
        dashboard_contract: ContractAddress,
        swap_contract: ContractAddress,
        // Protocol configuration parameters
        protocol_fee: u256, // Base points (1 = 0.01%)
        min_guardians: u8, // Minimum guardians per plan
        max_guardians: u8, // Maximum guardians per plan
        min_timelock: u64, // Minimum timelock period in seconds
        max_timelock: u64, // Maximum timelock period in seconds
        is_paused: bool, // Protocol pause state
        // Protocol statistics for analytics
        total_plans: u256,
        active_plans: u256,
        claimed_plans: u256,
        total_value_locked: u256,
        total_fees_collected: u256,
        // Plan details
        plan_asset_owner: Map<u256, ContractAddress>, // plan_id -> asset_owner
        plan_creation_date: Map<u256, u64>, // plan_id -> creation_date
        plan_transfer_date: Map<u256, u64>, // plan_id -> transfer_date
        plan_message: Map<u256, felt252>, // plan_id -> message
        plan_total_value: Map<u256, u256>, // plan_id -> total_value
        // Beneficiaries
        plan_beneficiaries_count: Map<u256, u32>, // plan_id -> beneficiaries_count
        plan_beneficiaries: Map<(u256, u32), ContractAddress>, // (plan_id, index) -> beneficiary
        is_beneficiary: Map<
            (u256, ContractAddress), bool,
        >, // (plan_id, beneficiary) -> is_beneficiary
        // Beneficiary to Recipient Mapping
        funds: Map<u256, SimpleBeneficiary>,
        plans_id: u256,
        // Dummy Mapping For transfer
        balances: Map<ContractAddress, u256>,
        deployed: bool,
    }

    #[event]
    #[derive(Copy, Drop, Debug, PartialEq, starknet::Event)]
    enum Event {
        BeneficiaryAdded: BeneficiaryAdded,
    }

    #[derive(Copy, Drop, Debug, PartialEq, starknet::Event)]
    struct BeneficiaryAdded {
        plan_id: u256,
        beneficiary_id: u32,
        address: ContractAddress,
        name: felt252,
        email: felt252,
    }

    #[constructor]
    fn constructor(ref self: ContractState) { // Initialize contract state:
        // 1. Set admin address
        // 2. Set default protocol parameters:
        //    - protocol_fee = 50 (0.5%)
        //    - min_guardians = 1
        //    - max_guardians = 5
        //    - min_timelock = 7 days
        //    - max_timelock = 365 days
        // 3. Initialize all statistics to 0
        // 4. Set is_paused to false
        self.deployed.write(true);
    }

    #[abi(embed_v0)]
    impl IInheritXImpl of IInheritX<ContractState> { // Contract Management Functions
        // Initialize a new claim with a claim code
        /// Initiates a claim for an inheritance plan by creating a new beneficiary entry
        /// and processing the payout.
        ///
        /// @param name - The name of the beneficiary.
        /// @param email - The email address of the beneficiary.
        /// @param beneficiary - The wallet address of the beneficiary.
        /// @param personal_message - A message associated with the inheritance.
        /// @param amount - The amount allocated for the beneficiary.
        /// @param claim_code - A unique code assigned to the claim.
        /// @param amountt - (Unused) Duplicate of `amount`, consider removing if unnecessary.
        /// @return felt252 - Returns `1` on successful claim initiation.
        fn create_claim(
            ref self: ContractState,
            name: felt252,
            email: felt252,
            beneficiary: ContractAddress,
            personal_message: felt252,
            amount: u256,
            claim_code: u256,
        ) -> u256 {
            let inheritance_id = self.plans_id.read(); // Use it before incrementing
            // Create a new beneficiary record
            let new_beneficiary = SimpleBeneficiary {
                id: inheritance_id,
                name,
                email,
                wallet_address: beneficiary,
                personal_message,
                amount,
                code: claim_code, // Ensure type compatibility
                claim_status: false,
                benefactor: get_caller_address(),
            };

            // Store the beneficiary details in the `funds` mapping
            self.funds.write(inheritance_id, new_beneficiary);

            // Increment the plan ID after storing the new entry

            self.plans_id.write(inheritance_id + 1);

            // Transfer funds as part of the claim process
            self.transfer_funds(get_contract_address(), amount);

            // Return success code
            inheritance_id
        }
        /// Allows a beneficiary to collect their claim.
        /// @param self - The contract state.
        /// @param inheritance_id - The ID of the inheritance claim.
        /// @param beneficiary - The wallet address of the beneficiary.
        /// @param claim_code - The unique code to verify the claim.
        /// @returns `true` if the claim is successfully collected, otherwise `false`.
        fn collect_claim(
            ref self: ContractState,
            inheritance_id: u256,
            beneficiary: ContractAddress,
            claim_code: u256,
        ) -> bool {
            // Retrieve the claim details from storage
            let mut claim = self.funds.read(inheritance_id);

            // Ensure the claim has not been collected before
            assert(!claim.claim_status, 'You have already made a claim');

            // Verify that the correct beneficiary is making the claim
            assert((claim.wallet_address == beneficiary), 'Not your claim');

            // Verify that the provided claim code matches the stored one
            assert((claim.code == claim_code), 'Invalid claim code');

            // Mark the claim as collected
            claim.claim_status = true;

            // Transfer the funds to the beneficiary
            self.transfer_funds(beneficiary, claim.amount);

            // Update the claim in storage after modifying it
            self.funds.write(inheritance_id, claim);
            // Return success status
            true
        }

        fn add_beneficiary(
            ref self: ContractState,
            plan_id: u256,
            name: felt252,
            email: felt252,
            address: ContractAddress,
        ) -> felt252 {
            // 1. Check if plan exists by verifying asset owner
            let asset_owner = self.plan_asset_owner.read(plan_id);
            assert(asset_owner != address, 'Invalid plan_id');

            // 2. Verify caller is asset owner
            let caller = starknet::get_caller_address();
            assert(caller == asset_owner, 'Caller is not the asset owner');

            // 3. Check plan state
            assert(self.plan_transfer_date.read(plan_id) == 0, 'Plan is already executed');

            // 4. Validate beneficiary address
            assert(!address.is_zero(), 'Invalid beneficiary address');
            assert(!self.is_beneficiary.read((plan_id, address)), 'Adlready a beneficiary');

            // 5. Validate input data
            assert(name != 0, 'Name cannot be empty');
            assert(email != 0, 'Email cannot be empty');

            // 6. Get and validate beneficiary count
            let current_count: u32 = self.plan_beneficiaries_count.read(plan_id);
            let max_allowed: u32 = self.max_guardians.read().into();
            assert(current_count < max_allowed, 'Exceeds max beneficiaries');

            // 7. Update state
            self.plan_beneficiaries.write((plan_id, current_count), address);
            self.is_beneficiary.write((plan_id, address), true);
            self.plan_beneficiaries_count.write(plan_id, current_count + 1);

            self
                .emit(
                    Event::BeneficiaryAdded(
                        BeneficiaryAdded {
                            plan_id, beneficiary_id: current_count, address, name, email,
                        },
                    ),
                );

            // 8. Return the new beneficiary ID
            current_count.into()
        }

        fn set_plan_asset_owner(ref self: ContractState, plan_id: u256, owner: ContractAddress) {
            self.plan_asset_owner.write(plan_id, owner);
        }

        fn set_max_guardians(ref self: ContractState, max_guardian_number: u8) {
            self.max_guardians.write(max_guardian_number);
        }

        fn get_plan_beneficiaries_count(self: @ContractState, plan_id: u256) -> u32 {
            let count = self.plan_beneficiaries_count.read(plan_id);
            count
        }

        fn get_plan_beneficiaries(
            self: @ContractState, plan_id: u256, index: u32,
        ) -> ContractAddress {
            let beneficiary = self.plan_beneficiaries.read((plan_id, index));
            beneficiary
        }

        fn get_total_plans(self: @ContractState) -> u256 {
            let total_plans = self.total_plans.read();
            total_plans
        }

        fn is_beneficiary(self: @ContractState, plan_id: u256, address: ContractAddress) -> bool {
            self.is_beneficiary.read((plan_id, address))
        }

        fn set_plan_transfer_date(ref self: ContractState, plan_id: u256, date: u64) {
            self.plan_transfer_date.write(plan_id, date);
        }


        // Dummy Functions
        /// Retrieves the details of a claim using the inheritance ID.
        /// @param self - The contract state.
        /// @param inheritance_id - The ID of the inheritance claim.
        /// @returns The `SimpleBeneficiary` struct containing the claim details.
        fn retrieve_claim(ref self: ContractState, inheritance_id: u256) -> SimpleBeneficiary {
            self.funds.read(inheritance_id)
        }

        fn transfer_funds(ref self: ContractState, beneficiary: ContractAddress, amount: u256) {
            let current_bal = self.balances.read(beneficiary);
            self.balances.write(beneficiary, current_bal + amount);
        }
        fn test_deployment(ref self: ContractState) -> bool {
            self.deployed.read()
        }
    }
}
