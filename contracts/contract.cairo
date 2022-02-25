# Declare this file as a StarkNet contract and set the required
# builtins.
%lang starknet
%builtins pedersen range_check

from starkware.cairo.common.cairo_builtins import HashBuiltin
from starkware.cairo.common.dict_access import DictAccess
from starkware.cairo.common.dict import dict_read, dict_write
from starkware.cairo.common.math import assert_nn_le
from starkware.cairo.common.registers import get_fp_and_pc
from starkware.cairo.common.math import unsigned_div_rem

#maximum amount of each token that belongs to AMM
const MAX_BALANCE  = 2 ** 64 - 1

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
            f'Swap: Account {ids.transaction.account_id} '
            f'gave {ids.a} tokens of type_a and '
            f'recieved {ids.b} tokens of type token_b.')
    %}

    return (state=new_state)

end

# Define a storage variable.
@storage_var
func balance() -> (res : felt):
end

