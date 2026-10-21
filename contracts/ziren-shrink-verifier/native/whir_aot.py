"""Ahead-of-time Yul WHIR tail for one approved shrink profile.

This is a line-for-line port of the patched StackedWhir.verify path that the
native build selects (fixed WHIR profile, offloaded query folds, calldata leaf
views and the code-pinned closing module). Every shape is a build-time constant
taken from the authenticated program tail; every proof value is read from the
verifyContext calldata at a fixed offset. The generated contract keeps the
Solidity tail's ABI, checks and error stages, so the entry pins its runtime
hash exactly as before.
"""
from Crypto.Hash import keccak

P = 0x7f000001


def selector(signature):
    return '0x' + keccak.new(digest_bits=256, data=signature.encode()).hexdigest()[:8]


def error(signature):
    return selector(signature)


def aot_whir_source(c, helpers_source, transcript_base, cfg, roots, stripes, point, p, closing_hash):
    """Return a Yul object named CompiledWhirVerifier.

    c: native Compiler (registers, packet offsets, metadata, ref checks)
    helpers_source: kernel helper functions (field arithmetic and transcript)
    transcript_base: memory address the helpers use for transcript state
    cfg, roots, stripes, point, p: wire.parse(c.tail)
    closing_hash: pinned runtime hash of the query and closing module
    """
    nf, nh = c.meta['field_count'], c.meta['hash_count']
    context_length = c.packet + c.wire_bytes
    base = 100  # selector, bytes offset, closing address, bytes length
    packet = base + c.packet
    fields_at = packet + 38
    hashes_at = packet + 38 + 4 * nf
    t = transcript_base
    whir_error = error('InvalidWhir(uint256)')
    shape_error = error('InvalidTranscriptShape()')
    out = []
    emit = out.append

    def value(ref):
        c.ref(ref)
        if ref & 0x80000000:
            return hex(ref & 0x7fffffff)
        index = ref & 0x0fffffff
        if ref & 0x40000000:
            return f'le32(calldataload({fields_at + 4 * index}))'
        if ref & 0x20000000:
            return f'reverse128(shr(128,calldataload({fields_at + 4 * index})))'
        if ref & 0x10000000:
            return f'calldataload({hashes_at + 32 * index})'
        assert ref < c.registers
        return f'calldataload({base + 32 * ref})'

    def field_kind(ref):
        return c.field_kind(ref)

    # Fixed memory map. The transcript helpers own [t, t+288).
    mem = t + 320
    randomness_at = mem
    mem += 32 * (cfg['n'])
    lambda_at = mem
    batch_lengths = [len(row) for row in p['batch']]
    mem += 32 * sum(batch_lengths)
    rounds = cfg['rounds']
    constraint_points = []          # (memory address of point, length) per affine OOD constraint
    query_counts = [r['queries'] for r in rounds[:-1]]
    ood_counts = [r['ood'] for r in rounds[:-1]]
    max_queries = max(query_counts + [cfg['finalQueries']])
    bases_at = mem
    mem += 32 * sum(query_counts)
    coeffs_at = mem
    total_constraints = sum(query_counts) + sum(ood_counts)
    mem += 32 * total_constraints
    ood_at = mem
    rem = cfg['n']
    folded = 0
    ood_layout = []
    for r, rc in enumerate(rounds[:-1]):
        folded += rc['fold']
        rem = cfg['n'] - folded
        for j in range(rc['ood']):
            ood_layout.append((r, j, mem, rem))
            mem += 32 * rem
    indices_at = mem
    mem += 32 * max_queries
    scratch = (mem + 31) // 32 * 32
    final_bases = scratch + 32 * max_queries
    poly_at = final_bases + 32 * cfg['finalQueries']
    request_at = poly_at + 32 * len(p['finalPoly'])
    request_words = 1 + cfg['n']
    folded_words = 0
    for rc in rounds[:-1]:
        folded_words += rc['fold']
        request_words += rc['ood'] * (1 + cfg['n'] - folded_words) + rc['queries']
    free_memory = request_at + 32 * request_words
    heights = set()

    emit(f'mstore(0x40,memoryguard({free_memory}))')
    # ABI: verifyContext(bytes context,address closingModule)
    emit(f'if iszero(eq(shr(224,calldataload(0)),{selector("verifyContext(bytes,address)")})) {{ revert(0,0) }}')
    emit(f'if iszero(eq(calldataload(4),64)) {{ revert(0,0) }}')
    emit(f'if iszero(eq(calldataload(68),{context_length})) {{ revert(0,0) }}')
    emit(f'if lt(calldatasize(),{base + context_length}) {{ revert(0,0) }}')
    emit('let closing:=calldataload(36)')
    emit(f'if shr(160,closing) {{ revert(0,0) }}')
    emit(f'if iszero(eq(extcodehash(closing),{closing_hash})) {{ revert(0,0) }}')
    # Resume the transcript exactly as KeccakTranscript.resume does.
    emit(f'calldatacopy({t},{base + 32 * c.registers},288)')
    emit(f'if or(iszero(lt(mload({t + 32}),100)),gt(mload({t + 64}),8)) {{ fail({shape_error}) }}')
    emit('let claim:=0')

    def check(condition_bad, stage):
        emit(f'if {condition_bad} {{ mstore(0,shl(224,{whir_error})) mstore(4,{stage}) revert(0,36) }}')

    # Batch evaluations, batch grinding and lambda powers.
    for row in p['batch']:
        for ref in row:
            assert field_kind(ref) == 'E'
            emit(f'observeE({value(ref)})')
    assert field_kind(p['batchPow']) == 'F'
    emit(f'grind({cfg["batchPow"]},{value(p["batchPow"])})')
    emit('{ let lambda:=sampleE() let lp:=1')
    k = 0
    for row in p['batch']:
        for ref in row:
            emit(f'claim:=plus(claim,times(lp,{value(ref)})) mstore({lambda_at + 32 * k},lp) lp:=times(lp,lambda)')
            k += 1
    emit('}')
    emit('pop(sampleE())')  # the native stacked path discards the initial OOD batch

    domain_log = cfg['n'] - rounds[0]['fold'] + cfg['startingRate']
    folded = 0
    pow_at = 0
    constraint_index = 0
    base_index = 0
    ood_index = 0
    open_rounds = p['openings']
    data_views = []
    for ri, leaves in enumerate(open_rounds):
        contiguous = [v for leaf in leaves for row in leaf['values'] for v in row]
        first = contiguous[0] & 0x0fffffff
        assert contiguous == list(range(contiguous[0], contiguous[0] + len(contiguous)))
        data_views.append((fields_at + 4 * first, 4 * len(contiguous)))

    def leaf_loop(leaf_list, rows, width, root_expr, height):
        """One loop over queries; leaf and path offsets must advance by fixed strides."""
        def place(leaf):
            flat = [v for row in leaf['values'] for v in row]
            assert len(flat) == rows * width and flat == list(range(flat[0], flat[0] + len(flat)))
            path = leaf['path']
            assert path == list(range(path[0], path[0] + len(path))) and len(path) == height
            return fields_at + 4 * (flat[0] & 0x0fffffff), hashes_at + 32 * (path[0] & 0x0fffffff)
        places = [place(leaf) for leaf in leaf_list]
        (f0, h0) = places[0]
        fs = places[1][0] - f0 if len(places) > 1 else 0
        hs = places[1][1] - h0 if len(places) > 1 else 0
        assert all(pl == (f0 + q * fs, h0 + q * hs) for q, pl in enumerate(places)), 'non-uniform leaf layout'
        emit(f'''for {{ let q:=0 }} lt(q,{len(places)}) {{ q:=add(q,1) }} {{
            merkle{height}(add({f0},mul(q,{fs})),{4 * rows * width},add({h0},mul(q,{hs})),mload(add({indices_at},mul(q,32))),{root_expr}) }}''')
        heights.add(height)

    def call_domain_powers(log, count, src, dst):
        emit(f'''{{ let buffer:=mload(0x40)
          mstore(buffer,shl(224,{selector("domainPowers(uint256,uint256[])")}))
          mstore(add(buffer,4),{log}) mstore(add(buffer,36),64) mstore(add(buffer,68),{count})
          mcopy(add(buffer,100),{src},{32 * count})
          if iszero(staticcall(gas(),closing,buffer,{100 + 32 * count},0,0)) {{ returndatacopy(buffer,0,returndatasize()) revert(buffer,returndatasize()) }}
          if iszero(eq(returndatasize(),{64 + 32 * count})) {{ fail({whir_error}) }}
          returndatacopy(buffer,0,{64 + 32 * count})
          if or(iszero(eq(mload(buffer),32)),iszero(eq(mload(add(buffer,32)),{count}))) {{ fail({whir_error}) }}
          mcopy({dst},add(buffer,64),{32 * count}) }}''')

    def call_fold(round_index, count, fold_point_at, fold_len, initial):
        offset, length = data_views[round_index]
        padded = (length + 31) // 32 * 32
        if initial:
            rows = batch_lengths
            sig = 'foldInitialCanonical(bytes,uint256[][],uint256)'
            lp_bytes = 32 + 32 * len(rows) + sum(32 + 32 * n for n in rows)
            body = [f'mstore(add(buffer,4),96) mstore(add(buffer,36),{96 + 32 + padded}) mstore(add(buffer,68),mload({fold_point_at}))',
                    f'mstore(add(buffer,100),{length}) calldatacopy(add(buffer,132),{offset},{length})']
            at = 4 + 96 + 32 + padded
            body.append(f'mstore(add(buffer,{at}),{len(rows)})')
            heads = at + 32
            cursor = 32 * len(rows)
            lam = lambda_at
            for i, n in enumerate(rows):
                body.append(f'mstore(add(buffer,{heads + 32 * i}),{cursor})')
                body.append(f'mstore(add(buffer,{heads + cursor}),{n}) mcopy(add(buffer,{heads + cursor + 32}),{lam},{32 * n})')
                lam += 32 * n
                cursor += 32 + 32 * n
            size = at + lp_bytes
        else:
            sig = 'foldRowsCanonical(bytes,uint256[])'
            body = [f'mstore(add(buffer,4),64) mstore(add(buffer,36),{64 + 32 + padded})',
                    f'mstore(add(buffer,68),{length}) calldatacopy(add(buffer,100),{offset},{length})',
                    f'mstore(add(buffer,{4 + 64 + 32 + padded}),{fold_len}) mcopy(add(buffer,{4 + 64 + 32 + padded + 32}),{fold_point_at},{32 * fold_len})']
            size = 4 + 64 + 32 + padded + 32 + 32 * fold_len
        emit('{ let buffer:=mload(0x40)')
        emit(f'mstore(buffer,shl(224,{selector(sig)}))')
        for line in body:
            emit(line)
        emit(f'''if iszero(staticcall(gas(),closing,buffer,{size},0,0)) {{ returndatacopy(buffer,0,returndatasize()) revert(buffer,returndatasize()) }}
          if iszero(eq(returndatasize(),{64 + 32 * count})) {{ fail({whir_error}) }}
          returndatacopy(buffer,0,{64 + 32 * count})
          if or(iszero(eq(mload(buffer),32)),iszero(eq(mload(add(buffer,32)),{count}))) {{ fail({whir_error}) }}
          mcopy({scratch},add(buffer,64),{32 * count}) }}''')

    for r, rc in enumerate(rounds):
        last = r + 1 == len(rounds)
        polys = p['finalPolys'] if last else p['roundPolys'][r]
        assert len(polys) == rc['fold']
        start = folded
        for j in range(rc['fold']):
            a = polys[j]
            assert len(a) == 3 and all(field_kind(ref) == 'E' for ref in a)
            emit(f'{{ let a0:={value(a[0])} let a1:={value(a[1])} let a2:={value(a[2])}')
            check('iszero(eq(plus(plus(a0,a0),plus(a1,a2)),claim))', 3)
            emit('observeE(a0) observeE(a1) observeE(a2)')
            assert field_kind(p['foldPow'][pow_at]) == 'F'
            emit(f'grind({rc["foldPow"][j]},{value(p["foldPow"][pow_at])})')
            pow_at += 1
            emit(f'let x:=sampleE() mstore({randomness_at + 32 * folded},x)')
            emit('claim:=plus(a0,times(x,plus(a1,times(a2,x)))) }')
            folded += 1
        if last:
            break
        emit(f'append({value(p["roots"][r])},32)')
        rem = cfg['n'] - folded
        round_ood = []
        for j in range(rc['ood']):
            rr, jj, at, length = ood_layout[ood_index]
            assert (rr, jj, length) == (r, j, rem)
            ood_index += 1
            emit(f'for {{ let i:=0 }} lt(i,{rem}) {{ i:=add(i,1) }} {{ mstore(add({at},mul(i,32)),sampleE()) }}')
            ref = p['roundOod'][r][j]
            assert field_kind(ref) == 'E'
            emit(f'observeE({value(ref)})')
            round_ood.append((at, ref))
        assert field_kind(p['foldPow'][pow_at]) == 'F'
        emit(f'grind({rc["queryPow"]},{value(p["foldPow"][pow_at])})')
        pow_at += 1
        assert domain_log <= 32
        emit(f'for {{ let q:=0 }} lt(q,{rc["queries"]}) {{ q:=add(q,1) }} {{ mstore(add({indices_at},mul(q,32)),and(word(),{(1 << domain_log) - 1})) }}')
        round_bases = bases_at + 32 * base_index
        call_domain_powers(domain_log, rc['queries'], indices_at, round_bases)
        leaves = open_rounds[r]
        if r == 0:
            per_query = len(roots)
            assert len(leaves) == rc['queries'] * per_query
            for ri in range(per_query):
                leaf_loop(leaves[ri::per_query], stripes[ri], 2, value(roots[ri]), domain_log)
        else:
            assert len(leaves) == rc['queries']
            leaf_loop(leaves, 1, 4 << rc['fold'], value(p['roots'][r - 1]), domain_log)
        fold_point_at = randomness_at + 32 * start
        call_fold(r, rc['queries'], fold_point_at, rc['fold'], r == 0)
        emit('{ let batch:=sampleE() let coeff:=batch')
        for at, ref in round_ood:
            emit(f'claim:=plus(claim,times(coeff,{value(ref)})) mstore({coeffs_at + 32 * constraint_index},coeff) coeff:=times(coeff,batch)')
            constraint_index += 1
        emit(f'''for {{ let q:=0 }} lt(q,{rc["queries"]}) {{ q:=add(q,1) }} {{
            claim:=plus(claim,times(coeff,mload(add({scratch},mul(q,32)))))
            mstore(add({coeffs_at + 32 * constraint_index},mul(q,32)),coeff) coeff:=times(coeff,batch) }} }}''')
        constraint_index += rc['queries']
        base_index += rc['queries']
        domain_log = rem - rounds[r + 1]['fold'] + rc['rate']

    # Final polynomial, final grinding and final queries.
    final_poly = p['finalPoly']
    assert all(field_kind(ref) == 'E' for ref in final_poly)
    for ref in final_poly:
        emit(f'observeE({value(ref)})')
    assert field_kind(p['finalPow']) == 'F'
    emit(f'grind({cfg["finalPow"]},{value(p["finalPow"])})')
    last_fold = rounds[-1]['fold']
    final_round = len(rounds) - 1
    leaves = open_rounds[final_round]
    assert len(leaves) == cfg['finalQueries']
    emit(f'for {{ let q:=0 }} lt(q,{cfg["finalQueries"]}) {{ q:=add(q,1) }} {{ mstore(add({indices_at},mul(q,32)),and(word(),{(1 << domain_log) - 1})) }}')
    leaf_loop(leaves, 1, 4 << last_fold, value(p['roots'][final_round - 1]), domain_log)
    call_domain_powers(domain_log, cfg['finalQueries'], indices_at, final_bases)
    call_fold(final_round, cfg['finalQueries'], randomness_at + 32 * (folded - last_fold), last_fold, False)
    # finalFolded[q] == Horner(finalPoly, finalBases[q]).
    for i, ref in enumerate(final_poly):
        emit(f'{{ let v:={value(ref)} mstore({poly_at + 32 * i},or(or(and(v,0xffffffff),shl(64,and(shr(32,v),0xffffffff))),or(shl(128,and(shr(64,v),0xffffffff)),shl(192,and(shr(96,v),0xffffffff))))) }}')
    emit(f'''for {{ let q:=0 }} lt(q,{cfg["finalQueries"]}) {{ q:=add(q,1) }} {{
        let x:=mload(add({final_bases},mul(q,32)))
        if iszero(lt(x,{P})) {{ fail({whir_error}) }}
        let acc:=0
        for {{ let src:={poly_at + 32 * len(final_poly)} }} gt(src,{poly_at}) {{}} {{
            src:=sub(src,32)
            let product:=add(mul(acc,x),mload(src))
            acc:=or(or(mod(and(product,0xffffffffffffffff),{P}),shl(64,mod(and(shr(64,product),0xffffffffffffffff),{P}))),or(shl(128,mod(and(shr(128,product),0xffffffffffffffff),{P})),shl(192,mod(shr(192,product),{P}))))
        }}
        let horner:=or(or(and(acc,0xffffffff),shl(32,and(shr(64,acc),0xffffffff))),or(shl(64,and(shr(128,acc),0xffffffff)),shl(96,shr(192,acc))))
        if iszero(eq(mload(add({scratch},mul(q,32))),horner)) {{ mstore(0,shl(224,{whir_error})) mstore(4,4) revert(0,36) }}
    }}''')

    # Closing request: initial affine constraint, then per round OOD (affine)
    # and query (monomial) constraints, in the Solidity tail's order.
    n = cfg['n']
    final_log = n - folded
    assert final_log == 5
    words = 1 + n
    folded_so_far = 0
    for r, rc in enumerate(rounds[:-1]):
        folded_so_far += rc['fold']
        rem = n - folded_so_far
        words += rc['ood'] * (1 + rem) + rc['queries']
    emit(f'mstore({request_at},{1 | (n << 128)})')
    assert len(point) == n
    for i, ref in enumerate(point):
        assert field_kind(ref) == 'E'
        emit(f'mstore({request_at + 32 * (1 + i)},{value(ref)})')
    cursor = 1 + n
    constraint_index = 0
    base_index = 0
    ood_index = 0
    folded_so_far = 0
    for r, rc in enumerate(rounds[:-1]):
        folded_so_far += rc['fold']
        rem = n - folded_so_far
        for j in range(rc['ood']):
            _, _, at, length = ood_layout[ood_index]
            ood_index += 1
            emit(f'mstore({request_at + 32 * cursor},or(mload({coeffs_at + 32 * constraint_index}),{rem << 128}))')
            emit(f'mcopy({request_at + 32 * (cursor + 1)},{at},{32 * rem})')
            cursor += 1 + rem
            constraint_index += 1
        emit(f'''for {{ let q:=0 }} lt(q,{rc["queries"]}) {{ q:=add(q,1) }} {{
            mstore(add({request_at + 32 * cursor},mul(q,32)),or(or(mload(add({coeffs_at + 32 * constraint_index},mul(q,32))),{(rem << 128) | (1 << 136)}),shl(160,mload(add({bases_at + 32 * base_index},mul(q,32))))))
        }}''')
        cursor += rc['queries']
        constraint_index += rc['queries']
        base_index += rc['queries']
    assert cursor == words
    random_count = folded
    emit('{ let buffer:=mload(0x40)')
    emit(f'mstore(buffer,shl(224,{selector("evaluate(uint256[],uint256[],uint256[])")}))')
    head = 4
    o_r = 96
    o_p = o_r + 32 + 32 * random_count
    o_q = o_p + 32 + 32 * len(final_poly)
    emit(f'mstore(add(buffer,{head}),{o_r}) mstore(add(buffer,{head + 32}),{o_p}) mstore(add(buffer,{head + 64}),{o_q})')
    emit(f'mstore(add(buffer,{head + o_r}),{random_count}) mcopy(add(buffer,{head + o_r + 32}),{randomness_at},{32 * random_count})')
    emit(f'mstore(add(buffer,{head + o_p}),{len(final_poly)})')
    for i, ref in enumerate(final_poly):
        emit(f'mstore(add(buffer,{head + o_p + 32 + 32 * i}),{value(ref)})')
    emit(f'mstore(add(buffer,{head + o_q}),{words}) mcopy(add(buffer,{head + o_q + 32}),{request_at},{32 * words})')
    size = head + o_q + 32 + 32 * words
    emit(f'''if iszero(staticcall(gas(),closing,buffer,{size},0,32)) {{ returndatacopy(buffer,0,returndatasize()) revert(buffer,returndatasize()) }}
      if iszero(eq(returndatasize(),32)) {{ revert(0,0) }}
      if iszero(eq(mload(0),claim)) {{ mstore(0,shl(224,{whir_error})) mstore(4,5) revert(0,36) }} }}''')
    emit('mstore(0,1) return(0,32)')

    def walker(height):
        # One fully unrolled path per height: each level hashes (node, sibling)
        # in the order the query index bit selects, as walkCalldata does.
        steps = '\n'.join(
            f'{{ let side:=shl(5,and(shr({k},index),1)) mstore(side,h) mstore(xor(side,32),calldataload(add(pathAt,{32 * k}))) h:=keccak256(0,64) }}'
            for k in range(height))
        return f'''
    function merkle{height}(leafAt,leafBytes,pathAt,index,root) {{
        let start:=mload(0x40)
        calldatacopy(start,leafAt,leafBytes)
        let h:=keccak256(start,leafBytes)
{steps}
        if iszero(eq(h,root)) {{ mstore(0,shl(224,{whir_error})) mstore(4,2) revert(0,36) }}
    }}'''
    merkle = ''.join(walker(height) for height in sorted(heights))
    body = '\n'.join(out)
    return f'''object "CompiledWhirVerifier" {{
  code {{ datacopy(0,dataoffset("Runtime"),datasize("Runtime")) return(0,datasize("Runtime")) }}
  object "Runtime" {{ code {{
{helpers_source}
{merkle}
{body}
  }} }}
}}'''
