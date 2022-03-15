import asyncio
import os
import pytest

from starkware.starknet.compiler.compile import compile_starknet_files
from starkware.starknet.services.api.contract_definition import ContractDefinition
from starkware.starknet.testing.starknet import Starknet

def contract_dir() -> str:
    here = os.path.abspath(os.path.dirname(__file__))
    return os.path.join(here, "..", "contracts")

def compile_contract(contract_name: str) -> ContractDefinition:
    contract_src = os.path.join(contract_dir(), contract_name)
    return compile_starknet_files(
        [contract_src], debug_info=True, disable_hint_validation=True, cairo_path=[contract_dir()]
    )

@pytest.fixture(scope="module")
def event_loop():
    return asyncio.new_event_loop()

@pytest.fixture(scope="module")
async def starknet():
    starknet = await Starknet.empty()
    return starknet

@pytest.fixture(scope="module")
async def amm(starknet):
    contract = compile_contract("amm.cairo")
    return await starknet.deploy(contract_def=contract)
