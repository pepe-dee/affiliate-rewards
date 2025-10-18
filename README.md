# Affiliate Rewards Smart Contract

A Clarity smart contract for managing merchant affiliate programs and rewards distribution on the Stacks blockchain.

## Overview

This smart contract enables merchants to create and manage affiliate programs, where affiliates can earn commissions from sales. The contract handles the secure distribution of rewards in STX tokens.

### Key Features

- **Program Management**: Merchants can create and update affiliate programs
- **Flexible Commission Rates**: Configurable rates in basis points (BPS)
- **Secure Fund Management**: Pre-funded merchant balances
- **Automated Rewards**: Direct commission calculations and distributions
- **Replay Protection**: Purchase IDs prevent double-processing
- **Safety Mechanisms**: 
  - Emergency pause functionality
  - State updates before transfers
  - Balance checks
  - Access controls

## Functions

### Admin Functions
- `set-treasury`: Set contract treasury address
- `pause`/`unpause`: Emergency controls

### Merchant Functions
- `create-program`: Create new affiliate program
- `update-program`: Modify existing program
- `fund-merchant`: Add funds to merchant balance
- `merchant-withdraw`: Withdraw unused funds
- `record-purchase`: Record sale and trigger commission

### Affiliate Functions
- `claim`: Withdraw earned commissions

### View Functions
- `get-program`: Get program details
- `merchant-balance`: Check merchant balance
- `affiliate-balance`: Check affiliate earnings
- `is-purchase-processed`: Verify purchase status

## Technical Details

- **Language**: Clarity 2.0
- **Platform**: Stacks Blockchain
- **Token**: STX (native token)
- **Commission Calculation**: Rate in BPS (basis points, 1/10000)

## Security Features

- Principal-based access control
- State validation before transfers
- Balance checks
- Replay protection
- Emergency pause mechanism

## Testing

To run tests:
```bash
clarinet test
```

## Deployment

Deploy using Clarinet:
```bash
clarinet deploy
```
