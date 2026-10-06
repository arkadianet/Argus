//! Pools as a graph of directed swaps, and exact quotes along a path.

use std::collections::{BTreeMap, HashSet};

use crate::math::{swap_input, swap_output, Curve};
use crate::pool::{Asset, Pool, PoolKind};

/// Pools kept per directed pair, deepest first. Bounds the cycle search the
/// same way the vendored router and Pantheon do.
pub const MAX_POOLS_PER_PAIR: usize = 3;

/// One swap direction through one pool.
#[derive(Debug, Clone, PartialEq)]
pub struct Edge {
    /// Index into the pool slice the graph was built from.
    pub pool: usize,
    pub from: Asset,
    pub to: Asset,
    pub reserve_in: u64,
    pub reserve_out: u64,
    pub fee_num: u32,
    /// Set when this swap takes ERG out of an N2T pool: the most it may.
    pub erg_out_cap: Option<u64>,
}

impl Edge {
    /// Both directions of `pool`.
    pub fn both(index: usize, pool: &Pool) -> [Edge; 2] {
        let [(x, rx), (y, ry)] = pool.sides();
        let cap = pool.erg_out_cap();
        let erg_cap = |to: &Asset| {
            if pool.kind == PoolKind::N2T && to.is_erg() {
                cap
            } else {
                None
            }
        };
        [
            Edge {
                pool: index,
                from: x.clone(),
                to: y.clone(),
                reserve_in: rx,
                reserve_out: ry,
                fee_num: pool.fee_num,
                erg_out_cap: erg_cap(&y),
            },
            Edge {
                pool: index,
                from: y,
                to: x.clone(),
                reserve_in: ry,
                reserve_out: rx,
                fee_num: pool.fee_num,
                erg_out_cap: erg_cap(&x),
            },
        ]
    }

    /// What the pool pays for `amount_in`, or `None` when it pays nothing
    /// or the payment would break the N2T storage floor.
    pub fn output(&self, amount_in: u64) -> Option<u64> {
        let out = swap_output(self.reserve_in, self.reserve_out, amount_in, self.fee_num);
        if out == 0 || self.erg_out_cap.is_some_and(|cap| out > cap) {
            return None;
        }
        Some(out)
    }

    /// The least input that makes the pool pay `amount_out`.
    pub fn input_for(&self, amount_out: u64) -> Option<u64> {
        if self.erg_out_cap.is_some_and(|cap| amount_out > cap) {
            return None;
        }
        swap_input(self.reserve_in, self.reserve_out, amount_out, self.fee_num)
    }
}

/// Amounts after each swap of `path` for `amount_in`, or `None` when any
/// swap pays nothing or breaks a pool's floor.
pub fn quote_path(path: &[&Edge], amount_in: u64) -> Option<Vec<u64>> {
    if path.is_empty() || amount_in == 0 {
        return None;
    }
    let mut amounts = Vec::with_capacity(path.len());
    let mut current = amount_in;
    for edge in path {
        current = edge.output(current)?;
        amounts.push(current);
    }
    Some(amounts)
}

/// The least input that makes `path` deliver at least `amount_out`.
pub fn input_for_path(path: &[&Edge], amount_out: u64) -> Option<u64> {
    let mut needed = amount_out;
    for edge in path.iter().rev() {
        needed = edge.input_for(needed)?;
    }
    Some(needed)
}

/// The path as one unrounded curve.
pub fn curve(path: &[&Edge]) -> Curve {
    path.iter().fold(Curve::identity(), |c, e| {
        c.then(e.reserve_in, e.reserve_out, e.fee_num)
    })
}

/// Directed swaps between assets.
#[derive(Debug, Clone, Default)]
pub struct PoolGraph {
    pub adjacency: BTreeMap<Asset, Vec<Edge>>,
    pub pool_count: usize,
}

impl PoolGraph {
    /// Both directions of every pool `include` accepts, keeping the
    /// [`MAX_POOLS_PER_PAIR`] deepest pools for each directed pair.
    pub fn build(pools: &[Pool], include: impl Fn(&Pool) -> bool) -> PoolGraph {
        let mut adjacency: BTreeMap<Asset, Vec<Edge>> = BTreeMap::new();
        let mut pool_count = 0;
        for (i, pool) in pools.iter().enumerate() {
            if !include(pool) {
                continue;
            }
            pool_count += 1;
            for edge in Edge::both(i, pool) {
                adjacency.entry(edge.from.clone()).or_default().push(edge);
            }
        }
        for edges in adjacency.values_mut() {
            // Deepest first per target; ties by pool id so a scan is
            // reproducible from the same pool set.
            edges.sort_by(|a, b| {
                a.to.cmp(&b.to)
                    .then(b.reserve_in.cmp(&a.reserve_in))
                    .then(pools[a.pool].pool_id.cmp(&pools[b.pool].pool_id))
            });
            let mut kept: Vec<Edge> = Vec::with_capacity(edges.len());
            for edge in edges.drain(..) {
                let same = kept.iter().filter(|k| k.to == edge.to).count();
                if same < MAX_POOLS_PER_PAIR {
                    kept.push(edge);
                }
            }
            *edges = kept;
        }
        PoolGraph {
            adjacency,
            pool_count,
        }
    }

    pub fn edges_from(&self, asset: &Asset) -> &[Edge] {
        self.adjacency.get(asset).map(Vec::as_slice).unwrap_or(&[])
    }

    /// Every cycle that starts and ends in ERG with at most `max_legs`
    /// swaps, using no pool twice and visiting no token twice. A cycle is
    /// a list of edges in trade order.
    pub fn erg_cycles(&self, max_legs: usize) -> Vec<Vec<Edge>> {
        let mut out = Vec::new();
        let mut path: Vec<Edge> = Vec::new();
        let mut seen_assets: HashSet<Asset> = HashSet::from([Asset::Erg]);
        let mut seen_pools: HashSet<usize> = HashSet::new();
        self.walk(
            &Asset::Erg,
            max_legs,
            &mut path,
            &mut seen_assets,
            &mut seen_pools,
            &mut out,
        );
        out
    }

    fn walk(
        &self,
        at: &Asset,
        max_legs: usize,
        path: &mut Vec<Edge>,
        seen_assets: &mut HashSet<Asset>,
        seen_pools: &mut HashSet<usize>,
        out: &mut Vec<Vec<Edge>>,
    ) {
        for edge in self.edges_from(at) {
            if seen_pools.contains(&edge.pool) {
                continue;
            }
            if edge.to.is_erg() {
                if !path.is_empty() {
                    let mut cycle = path.clone();
                    cycle.push(edge.clone());
                    out.push(cycle);
                }
                continue;
            }
            if path.len() + 2 > max_legs || seen_assets.contains(&edge.to) {
                continue;
            }
            seen_assets.insert(edge.to.clone());
            seen_pools.insert(edge.pool);
            path.push(edge.clone());
            self.walk(&edge.to, max_legs, path, seen_assets, seen_pools, out);
            path.pop();
            seen_pools.remove(&edge.pool);
            seen_assets.remove(&edge.to);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    pub(crate) fn n2t(id: &str, erg: u64, tok: &str, amount: u64) -> Pool {
        Pool::n2t(
            id,
            format!("box-{id}"),
            erg,
            tok,
            amount,
            format!("lp-{id}"),
            1_000,
            Some(997),
        )
        .unwrap()
    }

    pub(crate) fn t2t(id: &str, x: &str, xa: u64, y: &str, ya: u64) -> Pool {
        Pool::t2t(
            id,
            format!("box-{id}"),
            1_000_000,
            x,
            xa,
            y,
            ya,
            format!("lp-{id}"),
            1_000,
            Some(997),
        )
        .unwrap()
    }

    #[test]
    fn edges_respect_the_n2t_floor() {
        // 0.02 ERG pool: at most 0.01 ERG minus one nanoERG may leave.
        let p = n2t("p", 20_000_000, "tok", 1_000);
        let [_, to_erg] = Edge::both(0, &p);
        assert_eq!(to_erg.erg_out_cap, Some(9_999_999));
        assert!(to_erg.output(1).is_some());
        assert!(
            to_erg.output(1_000_000).is_none(),
            "would drain below the floor"
        );
        assert!(to_erg.input_for(10_000_000).is_none());
    }

    #[test]
    fn path_quotes_round_trip() {
        let pools = [
            n2t("a", 100_000_000_000, "tok", 1_000_000),
            n2t("b", 120_000_000_000, "tok", 1_000_000),
        ];
        let g = PoolGraph::build(&pools, |_| true);
        let cycles = g.erg_cycles(2);
        assert_eq!(cycles.len(), 2, "two directions through the two pools");
        let c = &cycles[0];
        let path: Vec<&Edge> = c.iter().collect();
        let amounts = quote_path(&path, 1_000_000_000).unwrap();
        let back = input_for_path(&path, *amounts.last().unwrap()).unwrap();
        assert!(back <= 1_000_000_000);
        assert!(*quote_path(&path, back).unwrap().last().unwrap() >= *amounts.last().unwrap());
    }

    #[test]
    fn cycles_use_each_pool_and_token_once() {
        let pools = [
            n2t("p1", 100_000_000_000, "A", 1_000_000),
            t2t("p2", "A", 500_000, "B", 800_000),
            n2t("p3", 200_000_000_000, "B", 500_000),
        ];
        let g = PoolGraph::build(&pools, |_| true);
        let cycles = g.erg_cycles(3);
        assert!(cycles.iter().any(|c| c.len() == 3));
        for c in &cycles {
            let pools: HashSet<usize> = c.iter().map(|e| e.pool).collect();
            assert_eq!(pools.len(), c.len(), "no pool twice");
            assert!(c.first().unwrap().from.is_erg() && c.last().unwrap().to.is_erg());
            for w in c.windows(2) {
                assert_eq!(w[0].to, w[1].from, "legs connect");
            }
        }
        assert!(g.erg_cycles(2).iter().all(|c| c.len() == 2));
        assert!(g.erg_cycles(2).is_empty(), "no two-leg loop in a triangle");
    }

    #[test]
    fn only_the_deepest_pools_per_pair_are_kept() {
        let pools: Vec<Pool> = (0..5)
            .map(|i| n2t(&format!("p{i}"), (i + 1) * 10_000_000_000, "tok", 1_000))
            .collect();
        let g = PoolGraph::build(&pools, |_| true);
        let from_erg = g.edges_from(&Asset::Erg);
        assert_eq!(from_erg.len(), MAX_POOLS_PER_PAIR);
        assert_eq!(from_erg[0].reserve_in, 50_000_000_000);
    }

    #[test]
    fn excluded_pools_are_not_edges() {
        let pools = [
            n2t("a", 100_000_000_000, "tok", 1_000),
            n2t("b", 1_000_000_000, "tok", 10),
        ];
        let g = PoolGraph::build(&pools, |p| p.value >= 50_000_000_000);
        assert_eq!(g.pool_count, 1);
        assert!(g.erg_cycles(3).is_empty());
    }
}
