// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;
import {KoalaBear as F} from "./KoalaBear.sol";
import {NativeClosingMath as M} from "./NativeClosingMath.sol";
import {INativeClosingEvaluator} from "./INativeClosingEvaluator.sol";

/// Auxiliary deterministic closing arithmetic, not a proof verifier. The full
/// entry computes all requests on chain and the WHIR tail pins this runtime.
contract NativeClosingEvaluator is INativeClosingEvaluator {
    error InvalidClosingInput();

    // Request evaluation is split into small helpers over one shared context so
    // the via-IR pipeline keeps every frame within the EVM stack limit.
    struct Context {
        uint256[] r;
        uint256[] polynomial;
        uint256[] widePolynomial;
        uint256[][] caches;
        uint256 prepared;
        uint256 finalLog;
    }

    function evaluate(uint256[] calldata randomness,uint256[] calldata finalPoly,uint256[] calldata requests)
        external pure returns(uint256 total) {
        Context memory c=_context(randomness,finalPoly);
        uint256 cursor;
        while(cursor<requests.length){
            uint256 header=requests[cursor++];
            uint256 vars=uint8(header>>128);
            if(header>>192!=0 || (header>>137)&0x7fffff!=0 || !F.canonical(uint128(header))
                || vars<c.finalLog || vars>c.r.length+c.finalLog)revert InvalidClosingInput();
            uint256 k=vars-c.finalLog;uint256 value;
            if((header>>136)&1!=0){
                value=_monomial(c,k,uint32(header>>160));
            }else{
                if(uint32(header>>160)!=0 || vars>requests.length-cursor)revert InvalidClosingInput();
                value=_affine(c,requests[cursor:cursor+vars],k);
                cursor+=vars;
            }
            total=F.add(total,F.mul(uint128(header),value));
        }
    }

    function _context(uint256[] calldata randomness,uint256[] calldata finalPoly)
        private pure returns(Context memory c) {
        uint256 length=finalPoly.length;
        if(length==0 || length&(length-1)!=0)revert InvalidClosingInput();
        uint256 finalLog;
        while(length>1){length>>=1;++finalLog;}
        if(finalLog>24 || randomness.length>24-finalLog)revert InvalidClosingInput();
        for(uint256 i;i<randomness.length;++i)if(!F.canonical(randomness[i]))revert InvalidClosingInput();
        for(uint256 i;i<finalPoly.length;++i)if(!F.canonical(finalPoly[i]))revert InvalidClosingInput();
        c.r=randomness;
        c.polynomial=finalPoly;
        c.widePolynomial=M.preparePolynomial(c.polynomial);
        c.caches=new uint256[][](c.r.length+1);
        c.finalLog=finalLog;
    }

    /// Monomial request: coefficient-free paired factor times the final
    /// polynomial at the folded point.
    function _monomial(Context memory c,uint256 k,uint256 x) private pure returns(uint256) {
        if(x>=F.P)revert InvalidClosingInput();
        if(c.prepared&(1<<k)==0){c.caches[k]=M.prepare(c.r,k);c.prepared|=1<<k;}
        (uint256 factor,uint256 finalX)=M.evaluate(c.caches[k],k,x);
        return F.mul(factor,M.hornerPrepared(c.widePolynomial,finalX));
    }

    /// Affine request: eq(point, randomness suffix) times the multilinear
    /// final polynomial at the remaining coordinates.
    function _affine(Context memory c,uint256[] calldata point,uint256 k) private pure returns(uint256) {
        uint256[] memory p=new uint256[](point.length);
        for(uint256 j;j<point.length;++j){
            uint256 value=point[j];
            if(!F.canonical(value))revert InvalidClosingInput();
            p[j]=value;
        }
        uint256 factor=1;
        for(uint256 j;j<k;++j){
            uint256 y=c.r[c.r.length-k+j];
            // eq(point,y) = (1-y) + (2*y-1)*point.
            factor=F.mul(factor,F.add(F.sub(1,y),F.mul(p[j],F.sub(F.add(y,y),1))));
        }
        return F.mul(factor,F.mle(c.polynomial,F.slice(p,k,c.finalLog)));
    }
}
