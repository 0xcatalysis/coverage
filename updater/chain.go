package main

import (
	"context"
	"crypto/ecdsa"
	"fmt"
	"math/big"

	"github.com/ethereum/go-ethereum"
	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/core/types"
	"github.com/ethereum/go-ethereum/crypto"
	"github.com/ethereum/go-ethereum/ethclient"
)

// ChainClient wraps an Ethereum JSON-RPC client and a signing key.
type ChainClient struct {
	client  *ethclient.Client
	privKey *ecdsa.PrivateKey
	from    common.Address
	chainID *big.Int
}

// newChainClient dials the RPC endpoint and derives the sender address from the
// hex-encoded private key (with or without 0x prefix).
func newChainClient(ctx context.Context, rpcURL, privateKeyHex string) (*ChainClient, error) {
	client, err := ethclient.DialContext(ctx, rpcURL)
	if err != nil {
		return nil, fmt.Errorf("dial rpc: %w", err)
	}

	chainID, err := client.ChainID(ctx)
	if err != nil {
		return nil, fmt.Errorf("get chain id: %w", err)
	}

	privKey, err := crypto.HexToECDSA(stripHexPrefix(privateKeyHex))
	if err != nil {
		return nil, fmt.Errorf("parse private key: %w", err)
	}

	return &ChainClient{
		client:  client,
		privKey: privKey,
		from:    crypto.PubkeyToAddress(privKey.PublicKey),
		chainID: chainID,
	}, nil
}

// close closes the underlying RPC connection.
func (c *ChainClient) close() {
	c.client.Close()
}

// readManagementFee performs a view call to managementFee() on the vault and
// returns the current fee as a *big.Int in WAD units.
func (c *ChainClient) readManagementFee(ctx context.Context, vault common.Address) (*big.Int, error) {
	calldata, err := encodeManagementFeeQuery()
	if err != nil {
		return nil, err
	}

	result, err := c.client.CallContract(ctx, ethereum.CallMsg{To: &vault, Data: calldata}, nil)
	if err != nil {
		return nil, fmt.Errorf("call managementFee on %s: %w", vault, err)
	}

	return decodeManagementFee(result)
}

// sendMulticall signs and broadcasts a multicall transaction to the vault.
// It waits for the transaction to be mined and returns the receipt.
func (c *ChainClient) sendMulticall(ctx context.Context, vault common.Address, calldata []byte) (*types.Receipt, error) {
	nonce, err := c.client.PendingNonceAt(ctx, c.from)
	if err != nil {
		return nil, fmt.Errorf("get nonce: %w", err)
	}

	gasPrice, err := c.client.SuggestGasPrice(ctx)
	if err != nil {
		return nil, fmt.Errorf("suggest gas price: %w", err)
	}

	gasLimit, err := c.client.EstimateGas(ctx, ethereum.CallMsg{
		From: c.from,
		To:   &vault,
		Data: calldata,
	})
	if err != nil {
		return nil, fmt.Errorf("estimate gas: %w", err)
	}
	// Add 20% buffer to the gas estimate.
	gasLimit = gasLimit * 12 / 10

	tx := types.NewTransaction(nonce, vault, big.NewInt(0), gasLimit, gasPrice, calldata)

	signed, err := types.SignTx(tx, types.NewLondonSigner(c.chainID), c.privKey)
	if err != nil {
		return nil, fmt.Errorf("sign tx: %w", err)
	}

	if err := c.client.SendTransaction(ctx, signed); err != nil {
		return nil, fmt.Errorf("send tx: %w", err)
	}

	receipt, err := waitForReceipt(ctx, c.client, signed.Hash())
	if err != nil {
		return nil, fmt.Errorf("wait for receipt (tx %s): %w", signed.Hash(), err)
	}
	if receipt.Status != types.ReceiptStatusSuccessful {
		return receipt, fmt.Errorf("tx %s reverted", signed.Hash())
	}

	return receipt, nil
}

// waitForReceipt polls for the receipt of txHash until the context is cancelled.
func waitForReceipt(ctx context.Context, client *ethclient.Client, txHash common.Hash) (*types.Receipt, error) {
	for {
		receipt, err := client.TransactionReceipt(ctx, txHash)
		if err == nil {
			return receipt, nil
		}
		if ctx.Err() != nil {
			return nil, ctx.Err()
		}
		select {
		case <-ctx.Done():
			return nil, ctx.Err()
		default:
		}
	}
}

func stripHexPrefix(s string) string {
	if len(s) >= 2 && s[:2] == "0x" {
		return s[2:]
	}
	return s
}
