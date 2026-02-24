package main

import (
	"fmt"
	"math/big"
	"strings"

	"github.com/ethereum/go-ethereum/accounts/abi"
	"github.com/ethereum/go-ethereum/common"
)

// vaultABIJSON is the minimal ABI for the Morpho VaultV2 functions used by this service:
//   - multicall(bytes[])          — batches submit + setManagementFee in one tx
//   - submit(bytes)               — queues a timelocked call
//   - setManagementFee(uint256)   — sets the management fee (WAD units)
//   - managementFee() uint96      — reads the current management fee
const vaultABIJSON = `[
  {
    "type": "function",
    "name": "multicall",
    "inputs": [{"name": "data", "type": "bytes[]"}],
    "outputs": [],
    "stateMutability": "nonpayable"
  },
  {
    "type": "function",
    "name": "submit",
    "inputs": [{"name": "data", "type": "bytes"}],
    "outputs": [],
    "stateMutability": "nonpayable"
  },
  {
    "type": "function",
    "name": "setManagementFee",
    "inputs": [{"name": "newManagementFee", "type": "uint256"}],
    "outputs": [],
    "stateMutability": "nonpayable"
  },
  {
    "type": "function",
    "name": "managementFee",
    "inputs": [],
    "outputs": [{"name": "", "type": "uint96"}],
    "stateMutability": "view"
  }
]`

// vaultABI is the parsed ABI, initialised once at startup by parseVaultABI.
var vaultABI abi.ABI

// parseVaultABI parses the inline ABI JSON and stores it in the package-level vaultABI.
// Must be called once before using any of the encoding helpers.
func parseVaultABI() error {
	parsed, err := abi.JSON(strings.NewReader(vaultABIJSON))
	if err != nil {
		return fmt.Errorf("parse vault ABI: %w", err)
	}
	vaultABI = parsed
	return nil
}

// encodeSetManagementFee returns the calldata for setManagementFee(feeWAD).
func encodeSetManagementFee(feeWAD *big.Int) ([]byte, error) {
	data, err := vaultABI.Pack("setManagementFee", feeWAD)
	if err != nil {
		return nil, fmt.Errorf("encode setManagementFee: %w", err)
	}
	return data, nil
}

// encodeSubmit returns the calldata for submit(innerCalldata).
func encodeSubmit(innerCalldata []byte) ([]byte, error) {
	data, err := vaultABI.Pack("submit", innerCalldata)
	if err != nil {
		return nil, fmt.Errorf("encode submit: %w", err)
	}
	return data, nil
}

// encodeMulticall returns the calldata for multicall([calls...]).
func encodeMulticall(calls [][]byte) ([]byte, error) {
	data, err := vaultABI.Pack("multicall", calls)
	if err != nil {
		return nil, fmt.Errorf("encode multicall: %w", err)
	}
	return data, nil
}

// encodeManagementFeeQuery returns the calldata for the managementFee() view call.
func encodeManagementFeeQuery() ([]byte, error) {
	data, err := vaultABI.Pack("managementFee")
	if err != nil {
		return nil, fmt.Errorf("encode managementFee: %w", err)
	}
	return data, nil
}

// decodeManagementFee decodes the result of a managementFee() call into a *big.Int.
func decodeManagementFee(result []byte) (*big.Int, error) {
	vals, err := vaultABI.Unpack("managementFee", result)
	if err != nil {
		return nil, fmt.Errorf("decode managementFee: %w", err)
	}
	if len(vals) == 0 {
		return nil, fmt.Errorf("empty managementFee result")
	}
	// The ABI type is uint96; go-ethereum unpacks it as a *big.Int.
	fee, ok := vals[0].(*big.Int)
	if !ok {
		return nil, fmt.Errorf("unexpected managementFee type %T", vals[0])
	}
	return fee, nil
}

// bpsToWAD converts a fee in basis points to Morpho's WAD representation.
// WAD = 1e18 (100%). Formula: feeWAD = bps * 1e18 / 10000.
func bpsToWAD(bps uint64) *big.Int {
	wad := new(big.Int).SetUint64(bps)
	wad.Mul(wad, new(big.Int).Exp(big.NewInt(10), big.NewInt(18), nil))
	wad.Div(wad, big.NewInt(10000))
	return wad
}

// wadToBps converts a Morpho WAD fee back to basis points (truncates).
func wadToBps(wad *big.Int) uint64 {
	bps := new(big.Int).Mul(wad, big.NewInt(10000))
	bps.Div(bps, new(big.Int).Exp(big.NewInt(10), big.NewInt(18), nil))
	return bps.Uint64()
}

// buildSubmitAndSetFeeMulticall builds the multicall payload that atomically
// submits and executes setManagementFee in a single transaction (valid only when
// the vault's timelock for setManagementFee is zero).
func buildSubmitAndSetFeeMulticall(_ common.Address, feeWAD *big.Int) ([]byte, error) {
	setFeeCalldata, err := encodeSetManagementFee(feeWAD)
	if err != nil {
		return nil, err
	}

	submitCalldata, err := encodeSubmit(setFeeCalldata)
	if err != nil {
		return nil, err
	}

	return encodeMulticall([][]byte{submitCalldata, setFeeCalldata})
}
