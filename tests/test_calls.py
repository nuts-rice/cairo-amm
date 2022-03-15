import os
import asyncio
#from pydoc import plain
import pytest

from starkware.starknet.public.abi import get_selector_from_name

@pytest.mark.asyncio
async def test_call_self(amm):
    selector = get_selector_from_name("forever_one")
    tx_info = await amm.call_self(selector).invoke()

    retdata = tx_info.result.retdata

    assert isinstance(retdata, list)
    assert len(retdata) == 1
    assert retdata[0] == 1
