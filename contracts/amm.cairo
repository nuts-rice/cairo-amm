# Declare this file as a StarkNet contract and set the required
# builtins.
%lang starknet
%builtins output pedersen range_check

from starkware.cairo.common.cairo_builtins import HashBuiltin
from starkware.cairo.common.hash import hash2
from starkware.cairo.common.dict_access import DictAccess
from starkware.cairo.common.dict import dict_read, dict_write, dict_new, dict_squash, dict_update
from starkware.cairo.common.math import assert_nn_le
from starkware.cairo.common.registers import get_fp_and_pc
from starkware.cairo.common.math import unsigned_div_rem
from starkware.cairo.common.small_merkle_tree import small_merkle_tree
from starkware.cairo.common.alloc import alloc
from starkware.starknet.common.syscalls import (
    call_contract, get_contract_address, get_caller_address, CallContractResponse)

#maximum amount of each token that belongs to AMM
const MAX_BALANCE  = 2 ** 64 - 1
const LOG_N_ACCOUNTS = 10

struct Account:
       member public_key : felt
       member token_a_balance : felt
       member token_b_balance : felt
end

struct AmmState:
       member account_dict_start : DictAccess*
       member account_dict_end : DictAccess*
       member token_a_balance : felt
       member token_b_balance : felt
end

struct SwapTransaction:
       member account_id : felt
       member token_a_amount : felt
end

struct AmmBatchOutput:
       #balances of AMM before/after applying batch
       member token_a_before : felt
       member token_b_before : felt
       member token_a_after : felt
       member token_b_after : felt
       #account merkle roots
       member account_root_before : felt
       member account_root_after : felt
end

func modify_account{range_check_ptr}(
     state : AmmState, account_id, diff_a, diff_b) -> (
     state : AmmState, key):
    alloc_locals

    #define reference to state.account_dict_end so that we have implicit argument to the dict functions
    let account_dict_end = state.account_dict_end

    #retrieve the pointer to current state of the account
    let (local old_account : Account*) = dict_read{
        dict_ptr=account_dict_end}(key=account_id)

    tempvar new_token_a_balance = (
        old_account.token_a_balance + diff_a)
    tempvar new_token_b_balance = (
        old_account.token_b_balance + diff_b)


    assert_nn_le(new_token_a_balance, MAX_BALANCE)
    assert_nn_le(new_token_b_balance, MAX_BALANCE)

    local new_account : Account
    assert new_account.public_key = old_account.public_key
    assert new_account.token_a_balance = new_token_a_balance
    assert new_account.token_b_balance = new_token_b_balance

    #perform update
    let (__fp__, _) = get_fp_and_pc()
    dict_write{dict_ptr=account_dict_end}(key=account_id, new_value=cast(&new_account, felt))

    #construct, return state
    local new_state: AmmState
    assert new_state.account_dict_start = (state.account_dict_start)
    assert new_state.account_dict_end = account_dict_end
    assert new_state.token_a_balance = state.token_a_balance
    assert new_state.token_b_balance = state.token_b_balance

    return (state=new_state, key=old_account.public_key)
end

func swap{range_check_ptr}(
     state : AmmState, transaction : SwapTransaction*) -> (state : AmmState):
    alloc_locals
    tempvar a = transaction.token_a_amount
    tempvar x = state.token_a_balance
    tempvar y = state.token_b_balance

    #check that token a is in range
    assert_nn_le(a, MAX_BALANCE)

    #compute swap for token b
    # b = (y * a) / (x + a)
    let (b, _) = unsigned_div_rem(y * a, x + a)

    assert_nn_le(b, MAX_BALANCE)

    #update
    let (state, key) = modify_account(
    state=state,
    account_id=transaction.account_id,
    diff_a=-a,
    diff_b=b)

    #TODO: user signature using public key from modify_account


    #figure balances of AMM and assert in range
    tempvar new_x = x + a
    tempvar new_y = y - b
    assert_nn_le(new_x, MAX_BALANCE)
    assert_nn_le(new_y, MAX_BALANCE)

    #update state
    local new_state : AmmState
    assert new_state.account_dict_start = (
    state.account_dict_start)
    assert new_state.account_dict_end = state.account_dict_end
    assert new_state.token_a_balance = new_x
    assert new_state.token_b_balance = new_y

    %{
        print(
            f'Swap: Account {ids.transaction.account_id}'
            f'gave {ids.a} tokens of type token_a and '
            f'recieved {ids.b} tokens of type token_b')
    %}

    return (state=new_state)

end

func transaction_loop{range_check_ptr}(
     state : AmmState, transactions : SwapTransaction**, number_transactions
     ) -> (state : AmmState):
    if number_transactions == 0:
       return (state=state)
    end

    let first_transaction : SwapTransaction* = [transactions]
    let (state) = swap(state=state, transaction=first_transaction)

    return transaction_loop(
    state=state,
    transactions=transactions + 1,
    number_transactions=number_transactions - 1)
end


func hash_account{pedersen_ptr : HashBuiltin*}(
     account : Account*) -> (res : felt):

     let res = account.public_key
     let (res) = hash2{hash_ptr=pedersen_ptr}(
         res, account.token_a_balance)
    let (res) = hash2{hash_ptr=pedersen_ptr}(
        res, account.token_b_balance)
    return (res=res)
end

func hash_dict_values{pedersen_ptr : HashBuiltin*}(
     dict_start : DictAccess*, dict_end : DictAccess*, hash_dict_start : DictAccess*
     ) -> (hash_dict_end : DictAccess*):
    if dict_start == dict_end:
       return (hash_dict_end=hash_dict_start)
    end

    #compute hash of account before and after change
    let (prev_hash) = hash_account(
        account=cast(dict_start.prev_value, Account*))
    let (new_hash) = hash_account(
        account=cast(dict_start.new_value, Account*))

    #add entry to result dict
    dict_update{dict_ptr=hash_dict_start}(
        key=dict_start.key,
        prev_value=prev_hash,
        new_value=new_hash)
    return hash_dict_values(
    dict_start=dict_start + DictAccess.SIZE,
    dict_end=dict_end,
    hash_dict_start=hash_dict_start)
end

func compute_merkle_roots{
     pedersen_ptr : HashBuiltin*, range_check_ptr}(
     state : AmmState) -> (root_before, root_after):
    alloc_locals

    let (squashed_dict_start, squashed_dict_end) = dict_squash(
        dict_accesses_start=state.account_dict_start,
        dict_accesses_end=state.account_dict_end)
    local range_check_ptr = range_check_ptr

    #Hash dict values
    #dict_new expects hint variable of initial_dict that specifies values of dictionary are before applying changes
    %{
        from starkware.crypto.signature.signature import pedersen_hash
        initial_dict = {}
        for account_id, account in initial_account_dict.items():
            public_key = memory[
                account + ids.Account.public_key]
            token_a_balance = memory[
                account + ids.Account.token_a_balance]
            token_b_balance = memory[
                account + ids.Account.token_b_balance]
            initial_dict[account_id] = pedersen_hash(
                pedersen_hash(public_key, token_a_balance),
                token_b_balance)
    %}

    #Compute the start and end merkle roots
    let (local hash_dict_start : DictAccess*) = dict_new()
    let (hash_dict_end) = hash_dict_values(
        dict_start=squashed_dict_start,
        dict_end=squashed_dict_end,
        hash_dict_start=hash_dict_start)

    #Compute two merkle roots for height of 2^10 accounts
    let (root_before, root_after) = small_merkle_tree{
        hash_ptr=pedersen_ptr}(
        squashed_dict_start=hash_dict_start,
        squashed_dict_end=hash_dict_end,
        height=LOG_N_ACCOUNTS)

    return(root_before=root_before, root_after=root_after)
end

func get_transactions() -> (transactions : SwapTransaction**, number_transactions : felt):
    alloc_locals
    local transactions : SwapTransaction**
    local number_transactions : felt
    %{
        transactions = [
            [
                transaction['account_id'],
                transaction['token_a_amount'],
            ]
            for transaction in program_input['transactions']
        ]
        ids.transactions = segments.gen_arg(transactions)
        ids.number_transactions = len(transactions)
    %}
    return (
    transactions = transactions,
    number_transactions=number_transactions)
end

func get_account_dict() -> (account_dict : DictAccess*):
     alloc_locals
     %{
        account = program_input['accounts']
        initial_dict = {
            int(account_id_str): segments.gen_arg([
                int(info['public_key'], 16),
                info['token_a_balance'],
                info['token_b_balance'],
                ])
                for account_id_str, info in account.items()

        }
        #save a copy of initial account dict for comput_merkle_roots
        initial_account_dict = dict(initial_dict)
    %}
    #init account dict
    let (account_dict) = dict_new()
    return (account_dict = account_dict)
end

@external
func call_self{syscall_ptr : felt*}(selector : felt) -> (retdata_len : felt, retdata : felt*):
    alloc_locals

    let (self) = get_contract_address()
    let (local ptr : felt*) = alloc()

    let response : CallContractResponse = call_contract(self, selector, 0, ptr)
    return (response.retdata_size, response.retdata)
end

@external
func plus_one{syscall_ptr : felt*}(value : felt) -> (value_plus_one : felt):
    return (value + 1)
end


func main {
     output_ptr : felt*, pedersen_ptr : HashBuiltin*,
     range_check_ptr}():

    alloc_locals
    local state : AmmState
    %{
        #initialize balances using a hint
        ids.state.token_a_balance = \
            program_input['token_a_balance']
        ids.state.token_b_balance = \
            program_input['token_b_balance']
    %}

    let (account_dict) = get_account_dict()
    assert state.account_dict_start = account_dict
    assert state.account_dict_end = account_dict

    let output = cast(output_ptr, AmmBatchOutput*)
    let output_ptr = output_ptr + AmmBatchOutput.SIZE

    assert output.token_a_before = state.token_a_balance
    assert output.token_b_before = state.token_b_balance

    let (transactions, number_transactions) = get_transactions()
    let (state : AmmState) = transaction_loop(
        state=state,
        transactions=transactions,
        number_transactions=number_transactions)

    assert output.token_a_after = state.token_a_balance
    assert output.token_b_after = state.token_b_balance

    let(root_before, root_after) = compute_merkle_roots(state=state)
    assert output.account_root_before = root_before
    assert output.account_root_after = root_after

    return()
end
