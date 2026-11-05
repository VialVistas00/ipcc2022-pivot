/*
 * pivot_opt.c - W04: precomputed distance matrix + OpenMP over pivot combinations
 *
 * Correctness contract: the per-combination objective value is accumulated in
 * exactly the same order as the reference pivot.c, so the ranking (including
 * ties) is bit-identical and result.txt matches refer-2dim-5h.txt byte for byte
 * after newline normalization.
 *
 * Build: gcc -O2 -fopenmp -o pivot_opt pivot_opt.c -lm
 * Run:   OMP_NUM_THREADS=8 ./pivot_opt uniformvector-2dim-5h.txt
 */
#include <stdio.h>
#include <stdlib.h>
#include <math.h>
#include <limits.h>
#include <sys/time.h>

#ifdef _OPENMP
#include <omp.h>
#endif

#define KEEP 1000

static int g_dim, g_n, g_k;
static double *g_dist;              /* column-major: g_dist[p*g_n + x] = d(p, x) */
static double *g_sums;              /* one objective value per combination */
static int *g_combos;               /* k pivot indices per combination */

static double *g_cmp_sums;
static int g_cmp_dir;               /* +1: descending (max), -1: ascending (min) */

static unsigned long long binom_ull(int nn, int rr) {
    if (rr < 0 || rr > nn) return 0;
    if (rr > nn - rr) rr = nn - rr;
    unsigned long long r = 1;
    for (int i = 1; i <= rr; i++) {
        unsigned long long num = (unsigned long long)(nn - rr + i);
        unsigned long long den = (unsigned long long)i;
        if (r > ULLONG_MAX / num) return ULLONG_MAX;
        r = r * num / den;
    }
    return r;
}

/* Same arithmetic as SumDistance() for k == 2, with rebuilt coordinates read
 * from the precomputed matrix. Diagonal pairs contribute exactly +0.0 and are
 * skipped; the sequence of non-zero additions is unchanged. */
static double sum_for_pivots2(const int *piv) {
    const double *p0 = g_dist + (size_t)piv[0] * g_n;
    const double *p1 = g_dist + (size_t)piv[1] * g_n;
    double sum = 0.0;

    for (int i = 0; i < g_n; i++) {
        const double ai0 = p0[i];
        const double ai1 = p1[i];

        for (int j = 0; j < i; j++) {
            double d0 = fabs(ai0 - p0[j]);
            double d1 = fabs(ai1 - p1[j]);
            double cheb = d0 > 0.0 ? d0 : 0.0;
            if (d1 > cheb) cheb = d1;
            sum += cheb;
        }
        for (int j = i + 1; j < g_n; j++) {
            double d0 = fabs(ai0 - p0[j]);
            double d1 = fabs(ai1 - p1[j]);
            double cheb = d0 > 0.0 ? d0 : 0.0;
            if (d1 > cheb) cheb = d1;
            sum += cheb;
        }
    }
    return sum;
}

/* Generic k path, also preserving the reference accumulation order. */
static double sum_for_pivots_generic(const int *piv, double *rebuilt) {
    for (int x = 0; x < g_n; x++) {
        for (int ki = 0; ki < g_k; ki++) {
            rebuilt[(size_t)x * g_k + ki] = g_dist[(size_t)piv[ki] * g_n + x];
        }
    }

    double sum = 0.0;
    for (int i = 0; i < g_n; i++) {
        for (int j = 0; j < g_n; j++) {
            if (i == j) continue;
            double cheb = 0.0;
            for (int ki = 0; ki < g_k; ki++) {
                double dis = fabs(rebuilt[(size_t)i * g_k + ki] -
                                  rebuilt[(size_t)j * g_k + ki]);
                if (dis > cheb) cheb = dis;
            }
            sum += cheb;
        }
    }
    return sum;
}

static void eval_leaf(const int *piv, unsigned long long rank, double *rebuilt) {
    double sum = (g_k == 2) ? sum_for_pivots2(piv)
                            : sum_for_pivots_generic(piv, rebuilt);
    g_sums[rank] = sum;
    int *dst = g_combos + (size_t)rank * g_k;
    for (int ki = 0; ki < g_k; ki++) dst[ki] = piv[ki];
}

/* Lexicographic enumeration with a running rank so every leaf writes its own
 * slot; rank order == reference enumeration order, which keeps ties stable. */
static void enumerate(int *piv, int depth, int start, unsigned long long base,
                      double *rebuilt) {
    if (depth == g_k) {
        eval_leaf(piv, base, rebuilt);
        return;
    }

    int rem = g_k - depth - 1;
    int last = g_n - (g_k - depth);
    unsigned long long offset = 0;
    for (int v = start; v <= last; v++) {
        piv[depth] = v;
        enumerate(piv, depth + 1, v + 1, base + offset, rebuilt);
        offset += binom_ull(g_n - v - 1, rem);
    }
}

static int cmp_cand(const void *pa, const void *pb) {
    unsigned long long a = *(const unsigned long long *)pa;
    unsigned long long b = *(const unsigned long long *)pb;
    double va = g_cmp_sums[a];
    double vb = g_cmp_sums[b];
    if (va > vb) return -g_cmp_dir;
    if (va < vb) return g_cmp_dir;
    return (a > b) - (a < b);
}

static double now_ms(void) {
    struct timeval tv;
    gettimeofday(&tv, NULL);
    return tv.tv_sec * 1000.0 + tv.tv_usec / 1000.0;
}

int main(int argc, char *argv[]) {
    const char *filename = "uniformvector-2dim-5h.txt";
    if (argc == 2) {
        filename = argv[1];
    } else if (argc != 1) {
        printf("Usage: ./pivot_opt <filename>\n");
        return -1;
    }

    double t_start = now_ms();

    FILE *file = fopen(filename, "r");
    if (file == NULL) {
        printf("%s file not found.\n", filename);
        return -1;
    }
    if (fscanf(file, "%d", &g_dim) != 1 ||
        fscanf(file, "%d", &g_n) != 1 ||
        fscanf(file, "%d", &g_k) != 1) {
        printf("bad input header\n");
        fclose(file);
        return -1;
    }
    printf("dim = %d, n = %d, k = %d\n", g_dim, g_n, g_k);
    if (g_n < 1 || g_k < 1 || g_k > g_n) {
        printf("invalid parameters\n");
        fclose(file);
        return -1;
    }

    double *coord = (double *)malloc(sizeof(double) * (size_t)g_dim * g_n);
    if (!coord) { printf("out of memory\n"); fclose(file); return -1; }
    for (int i = 0; i < g_n; i++) {
        for (int j = 0; j < g_dim; j++) {
            if (fscanf(file, "%lf", &coord[(size_t)i * g_dim + j]) != 1) {
                printf("bad input data\n");
                fclose(file);
                free(coord);
                return -1;
            }
        }
    }
    fclose(file);

    unsigned long long total = binom_ull(g_n, g_k);
    if (total == ULLONG_MAX || total > 50000000ULL) {
        printf("too many combinations for this implementation: %llu\n", total);
        free(coord);
        return -1;
    }

    double t_read = now_ms();

    /* Precompute every point-to-point distance once. Column-major layout makes
     * each pivot's distance vector contiguous in the inner loop. */
    g_dist = (double *)malloc(sizeof(double) * (size_t)g_n * g_n);
    if (!g_dist) { printf("out of memory\n"); free(coord); return -1; }
    for (int p = 0; p < g_n; p++) {
        for (int x = 0; x < g_n; x++) {
            double sq = 0.0;
            for (int j = 0; j < g_dim; j++) {
                double delta = coord[(size_t)p * g_dim + j] -
                               coord[(size_t)x * g_dim + j];
                sq += pow(delta, 2);
            }
            g_dist[(size_t)p * g_n + x] = sqrt(sq);
        }
    }
    free(coord);

    double t_dist = now_ms();

    g_sums = (double *)malloc(sizeof(double) * total);
    g_combos = (int *)malloc(sizeof(int) * (size_t)total * g_k);
    if (!g_sums || !g_combos) { printf("out of memory\n"); return -1; }

    unsigned long long *first_base =
        (unsigned long long *)malloc(sizeof(unsigned long long) * (size_t)(g_n - g_k + 1));
    if (!first_base) { printf("out of memory\n"); return -1; }
    unsigned long long acc = 0;
    for (int v = 0; v <= g_n - g_k; v++) {
        first_base[v] = acc;
        acc += binom_ull(g_n - v - 1, g_k - 1);
    }

    int threads = 1;
#ifdef _OPENMP
    threads = omp_get_max_threads();
#pragma omp parallel
    {
        int *piv = (int *)malloc(sizeof(int) * (size_t)g_k);
        double *rebuilt = (double *)malloc(sizeof(double) * (size_t)g_n * g_k);

#pragma omp for schedule(dynamic, 1)
        for (int v = 0; v <= g_n - g_k; v++) {
            piv[0] = v;
            enumerate(piv, 1, v + 1, first_base[v], rebuilt);
        }

        free(piv);
        free(rebuilt);
    }
#else
    {
        int *piv = (int *)malloc(sizeof(int) * (size_t)g_k);
        double *rebuilt = (double *)malloc(sizeof(double) * (size_t)g_n * g_k);
        for (int v = 0; v <= g_n - g_k; v++) {
            piv[0] = v;
            enumerate(piv, 1, v + 1, first_base[v], rebuilt);
        }
        free(piv);
        free(rebuilt);
    }
#endif

    double t_enum = now_ms();

    unsigned long long *order =
        (unsigned long long *)malloc(sizeof(unsigned long long) * total);
    if (!order) { printf("out of memory\n"); return -1; }
    for (unsigned long long i = 0; i < total; i++) order[i] = i;

    g_cmp_sums = g_sums;
    g_cmp_dir = 1;
    qsort(order, total, sizeof(unsigned long long), cmp_cand);
    unsigned long long *order_max =
        (unsigned long long *)malloc(sizeof(unsigned long long) * KEEP);
    for (int i = 0; i < KEEP; i++) order_max[i] = order[i];

    g_cmp_dir = -1;
    qsort(order, total, sizeof(unsigned long long), cmp_cand);

    double t_select = now_ms();
    double t_end = t_select;

    FILE *out = fopen("result.txt", "w");
    if (!out) { printf("cannot write result.txt\n"); return -1; }
    for (int i = 0; i < KEEP; i++) {
        const int *c = g_combos + (size_t)order_max[i] * g_k;
        for (int ki = 0; ki < g_k - 1; ki++) fprintf(out, "%d ", c[ki]);
        fprintf(out, "%d\n", c[g_k - 1]);
    }
    for (int i = 0; i < KEEP; i++) {
        const int *c = g_combos + (size_t)order[i] * g_k;
        for (int ki = 0; ki < g_k - 1; ki++) fprintf(out, "%d ", c[ki]);
        fprintf(out, "%d\n", c[g_k - 1]);
    }
    fclose(out);

    printf("Using time : %f ms\n", t_end - t_start);
    printf("[OPT] threads=%d combos=%llu read=%.1f ms dist=%.1f ms "
           "enum=%.1f ms select=%.1f ms\n",
           threads, total, t_read - t_start, t_dist - t_read,
           t_enum - t_dist, t_select - t_enum);

    const int *c = g_combos + (size_t)order_max[0] * g_k;
    printf("max : ");
    for (int ki = 0; ki < g_k; ki++) printf("%d ", c[ki]);
    printf("%lf\n", g_sums[order_max[0]]);
    c = g_combos + (size_t)order[0] * g_k;
    printf("min : ");
    for (int ki = 0; ki < g_k; ki++) printf("%d ", c[ki]);
    printf("%lf\n", g_sums[order[0]]);

    free(order_max);
    free(order);
    free(first_base);
    free(g_combos);
    free(g_sums);
    free(g_dist);
    return 0;
}
