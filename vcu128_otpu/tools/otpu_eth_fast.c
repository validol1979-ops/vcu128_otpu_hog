/* Быстрый путь EthTransport (otpu_eth.py): окно записи и чтения памяти по протоколу
 * doc/eth40_protocol.md на подключённом (connect) UDP-сокете, без root.
 *
 * Зачем: 2 ГБ/с — это ~250 тыс. кадров по 8 КиБ в секунду; цикл Python на кадр
 * (sendmsg/recv_into, разбор заголовка) даёт порядка 0,3–0,6 ГБ/с. Здесь sendmmsg/recvmmsg
 * пачками, данные записи уходят из буфера пользователя (iovec), данные чтения
 * копируются из кольца приёма на своё место по OFFSET ответа. ctypes отпускает GIL
 * на время вызова.
 *
 * Сборка (делает otpu_eth.py сам, в кэш пользователя):
 *     gcc -O2 -shared -fPIC -o otpu_eth_fast.so otpu_eth_fast.c
 * Коды возврата: 0 — успех; -1 — системная ошибка (errno); -2 — нет ответа после
 * retries повторов; -3 — STATUS ответа не 0 (код в *status, OFFSET в *bad_off).
 */
#define _GNU_SOURCE
#include <errno.h>
#include <poll.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/uio.h>
#include <time.h>

#define MAGIC_REQ  0x3034544Fu
#define MAGIC_RESP 0x5234544Fu
#define OP_WRITE 1
#define OP_READ  2
#define PHDR 22
#define BATCH 64
#define RXBUF 9216

static double now_s(void)
{
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return (double)t.tv_sec + 1e-9 * (double)t.tv_nsec;
}

static void put32(uint8_t *p, uint32_t v) { memcpy(p, &v, 4); }      /* little-endian хост */
static uint32_t get32(const uint8_t *p) { uint32_t v; memcpy(&v, p, 4); return v; }

static void mk_hdr(uint8_t *h, uint32_t seq, uint8_t op, uint8_t ch, uint32_t off,
                   uint32_t len, uint32_t aux)
{
    put32(h, MAGIC_REQ);
    put32(h + 4, seq);
    h[8] = op;
    h[9] = ch;
    put32(h + 10, off);
    put32(h + 14, len);
    put32(h + 18, aux);
}

/* приём ответов: до BATCH дейтаграмм без ожидания (или с ожиданием tmo_ms) */
struct rxring {
    uint8_t buf[BATCH][RXBUF];
    struct iovec iov[BATCH];
    struct mmsghdr msg[BATCH];
};

static int rx_batch(int fd, struct rxring *r, int tmo_ms)
{
    struct pollfd p = {.fd = fd, .events = POLLIN};
    int k = poll(&p, 1, tmo_ms);
    if (k < 0)
        return errno == EINTR ? 0 : -1;
    if (k == 0)
        return 0;
    for (int i = 0; i < BATCH; i++) {
        r->iov[i].iov_base = r->buf[i];
        r->iov[i].iov_len = RXBUF;
        memset(&r->msg[i].msg_hdr, 0, sizeof(r->msg[i].msg_hdr));
        r->msg[i].msg_hdr.msg_iov = &r->iov[i];
        r->msg[i].msg_hdr.msg_iovlen = 1;
    }
    int n = recvmmsg(fd, r->msg, BATCH, MSG_DONTWAIT, NULL);
    if (n < 0)
        return (errno == EAGAIN || errno == EWOULDBLOCK || errno == ECONNREFUSED) ? 0 : -1;
    return n;
}

/* ------------------------------------------------------------------ запись
 * buf[0..n) в канал ch с off; кадры по pkt байт (кратно 64), window кадров без
 * подтверждения; SEQ кадра i = *seq + i, *seq сдвигается на число кадров.
 * stats[0] — отправлено кадров (с повторами), stats[1] — повторов, stats[2] — лишних
 * подтверждений (дубли и чужие SEQ). */
int oe_write(int fd, uint32_t *seq, int ch, uint64_t off, const uint8_t *buf, uint64_t n,
             int pkt, int window, double rto, int retries, int64_t *stats,
             int *status, uint64_t *bad_off)
{
    uint64_t npk = (n + pkt - 1) / pkt;
    uint32_t seq0 = *seq;
    *seq = seq0 + (uint32_t)npk;
    if (npk == 0)
        return 0;
    double *sent = calloc(npk, sizeof(double));
    uint8_t *tries = calloc(npk, 1);
    uint8_t *acked = calloc(npk, 1);
    uint8_t (*hdr)[PHDR] = malloc(BATCH * PHDR);
    struct rxring *rx = malloc(sizeof(*rx));
    struct iovec iov[BATCH][2];
    struct mmsghdr msg[BATCH];
    uint64_t idx[BATCH];
    int rc = 0;
    if (!sent || !tries || !acked || !hdr || !rx) { rc = -1; errno = ENOMEM; goto out; }

    uint64_t nxt = 0, base = 0, done = 0, inflight = 0;
    uint64_t resend_from = 0;
    while (done < npk) {
        /* что отправить: повторы по таймауту, затем новые в пределах окна */
        int m = 0;
        double t = now_s();
        for (uint64_t i = resend_from; i < nxt && m < BATCH; i++) {
            if (acked[i] || t - sent[i] <= rto)
                continue;
            if (tries[i] > retries) { rc = -2; goto out; }
            idx[m++] = i;
            stats[1]++;
        }
        while (m < BATCH && nxt < npk && inflight < (uint64_t)window) {
            idx[m++] = nxt++;
            inflight++;
        }
        for (int j = 0; j < m; j++) {
            uint64_t i = idx[j], o = i * (uint64_t)pkt;
            uint32_t k = (uint32_t)((n - o) < (uint64_t)pkt ? (n - o) : (uint64_t)pkt);
            mk_hdr(hdr[j], seq0 + (uint32_t)i, OP_WRITE, (uint8_t)ch, (uint32_t)(off + o), k, 0);
            iov[j][0].iov_base = hdr[j];
            iov[j][0].iov_len = PHDR;
            iov[j][1].iov_base = (void *)(buf + o);
            iov[j][1].iov_len = k;
            memset(&msg[j].msg_hdr, 0, sizeof(msg[j].msg_hdr));
            msg[j].msg_hdr.msg_iov = iov[j];
            msg[j].msg_hdr.msg_iovlen = 2;
        }
        for (int j = 0; j < m;) {
            int s = sendmmsg(fd, msg + j, m - j, 0);
            if (s < 0) {
                if (errno == EINTR || errno == ENOBUFS || errno == EAGAIN || errno == ECONNREFUSED)
                    continue;
                rc = -1;
                goto out;
            }
            double ts = now_s();
            for (int q = j; q < j + s; q++) { sent[idx[q]] = ts; tries[idx[q]]++; }
            stats[0] += s;
            j += s;
        }
        /* подтверждения */
        int tmo = (inflight >= (uint64_t)window || nxt == npk) ? 1 : 0;
        int r = rx_batch(fd, rx, tmo);
        if (r < 0) { rc = -1; goto out; }
        for (int j = 0; j < r; j++) {
            const uint8_t *b = rx->buf[j];
            if (rx->msg[j].msg_len < PHDR || get32(b) != MAGIC_RESP || b[8] != OP_WRITE) {
                stats[2]++;
                continue;
            }
            uint64_t i = (uint32_t)(get32(b + 4) - seq0);
            if (i >= npk || acked[i]) { stats[2]++; continue; }
            if (b[9] != 0) {
                *status = b[9];
                *bad_off = get32(b + 10);
                rc = -3;
                goto out;
            }
            acked[i] = 1;
            done++;
            inflight--;
        }
        while (base < nxt && acked[base])
            base++;
        resend_from = base;
    }
out:
    free(sent); free(tries); free(acked); free(hdr); free(rx);
    return rc;
}

/* ------------------------------------------------------------------ чтение
 * n байт канала ch с off в buf. Запросы по reqlen байт (кратно fsz), не больше nreq в
 * полёте; ответные кадры по fsz байт кладутся по OFFSET. Запрос без новых кадров
 * дольше rto: его недостающие куски запрашиваются заново (новые SEQ); кадры прежних
 * SEQ этого вызова тоже принимаются. stats[0] — запросов, [1] — перезапросов,
 * [2] — лишних кадров (дубли, чужие), [3] — кадров принято. */
struct rreq {
    uint32_t seq;
    uint64_t f0, nf;        /* кадры [f0, f0 + nf) */
    uint64_t left;
    double t;               /* последняя активность */
    int tries;
};

int oe_read(int fd, uint32_t *seq, int ch, uint64_t off, uint8_t *buf, uint64_t n,
            int fsz, int reqlen, int nreq, double rto, int retries, int64_t *stats,
            int *status, uint64_t *bad_off)
{
    uint64_t nf = (n + fsz - 1) / fsz;
    uint64_t fpr = reqlen / fsz;            /* кадров на запрос */
    uint32_t seq0 = *seq;
    if (nf == 0)
        return 0;
    uint8_t *got = calloc(nf, 1);
    struct rreq *act = calloc(nreq, sizeof(*act));
    int nact = 0;
    struct rxring *rx = malloc(sizeof(*rx));
    int rc = 0;
    uint64_t next_f = 0, ngot = 0;
    /* очередь перезапросов: недостающие куски снятых запросов */
    uint64_t *rq_f0 = NULL, *rq_nf = NULL;
    int *rq_tries = NULL;
    size_t rq_n = 0, rq_cap = 0;
    if (!got || !act || !rx) { rc = -1; errno = ENOMEM; goto out; }

    while (ngot < nf) {
        /* новые запросы: сначала перезапросы, затем следующий кусок */
        while (nact < nreq && (rq_n || next_f < nf)) {
            struct rreq *q = &act[nact];
            if (rq_n) {
                rq_n--;
                q->f0 = rq_f0[rq_n];
                q->nf = rq_nf[rq_n];
                q->tries = rq_tries[rq_n];
                stats[1]++;
            } else {
                q->f0 = next_f;
                q->nf = (nf - next_f) < fpr ? (nf - next_f) : fpr;
                q->tries = 0;
                next_f += q->nf;
            }
            q->left = 0;
            for (uint64_t f = q->f0; f < q->f0 + q->nf; f++)
                q->left += !got[f];
            if (!q->left)
                continue;
            if (q->tries > retries) { rc = -2; goto out; }
            uint64_t o = q->f0 * (uint64_t)fsz;
            uint64_t e = (q->f0 + q->nf) * (uint64_t)fsz;
            if (e > n) e = n;
            uint8_t h[PHDR];
            q->seq = *seq;
            *seq += 1;
            mk_hdr(h, q->seq, OP_READ, (uint8_t)ch, (uint32_t)(off + o), (uint32_t)(e - o),
                   (uint32_t)fsz);
            for (;;) {
                ssize_t s = send(fd, h, PHDR, 0);
                if (s >= 0) break;
                if (errno == EINTR || errno == ENOBUFS || errno == EAGAIN || errno == ECONNREFUSED)
                    continue;
                rc = -1;
                goto out;
            }
            q->t = now_s();
            q->tries++;
            stats[0]++;
            nact++;
        }
        int r = rx_batch(fd, rx, 1);
        if (r < 0) { rc = -1; goto out; }
        for (int j = 0; j < r; j++) {
            const uint8_t *b = rx->buf[j];
            unsigned len = rx->msg[j].msg_len;
            if (len < PHDR || get32(b) != MAGIC_RESP || b[8] != OP_READ) { stats[2]++; continue; }
            uint32_t s = get32(b + 4);
            if ((uint32_t)(s - seq0) >= (uint32_t)(*seq - seq0)) { stats[2]++; continue; }
            if (b[9] != 0) {
                *status = b[9];
                *bad_off = get32(b + 10);
                rc = -3;
                goto out;
            }
            uint64_t fo = (uint32_t)(get32(b + 10) - (uint32_t)off);
            uint32_t fl = get32(b + 14);
            if (fo % fsz || fo >= n) { stats[2]++; continue; }
            uint64_t f = fo / fsz;
            uint64_t want = (n - fo) < (uint64_t)fsz ? (n - fo) : (uint64_t)fsz;
            if (fl != want || len < PHDR + fl || got[f]) { stats[2]++; continue; }
            memcpy(buf + fo, b + PHDR, fl);
            got[f] = 1;
            ngot++;
            stats[3]++;
            for (int k = 0; k < nact; k++) {
                if (f >= act[k].f0 && f < act[k].f0 + act[k].nf) {
                    act[k].left--;
                    act[k].t = now_s();
                    break;
                }
            }
        }
        /* снять законченные и просроченные запросы */
        double t = now_s();
        for (int k = 0; k < nact;) {
            struct rreq *q = &act[k];
            if (q->left && t - q->t > rto) {
                /* недостающие куски — в очередь перезапросов */
                for (uint64_t f = q->f0; f < q->f0 + q->nf;) {
                    if (got[f]) { f++; continue; }
                    uint64_t g = f;
                    while (g < q->f0 + q->nf && !got[g]) g++;
                    if (rq_n == rq_cap) {
                        rq_cap = rq_cap ? 2 * rq_cap : 16;
                        rq_f0 = realloc(rq_f0, rq_cap * sizeof(*rq_f0));
                        rq_nf = realloc(rq_nf, rq_cap * sizeof(*rq_nf));
                        rq_tries = realloc(rq_tries, rq_cap * sizeof(*rq_tries));
                        if (!rq_f0 || !rq_nf || !rq_tries) { rc = -1; errno = ENOMEM; goto out; }
                    }
                    rq_f0[rq_n] = f;
                    rq_nf[rq_n] = g - f;
                    rq_tries[rq_n] = q->tries;
                    rq_n++;
                    f = g;
                }
                q->left = 0;
            }
            if (!q->left) {
                act[k] = act[--nact];
                continue;
            }
            k++;
        }
    }
out:
    free(got); free(act); free(rx); free(rq_f0); free(rq_nf); free(rq_tries);
    return rc;
}

/* ------------------------------------------------------------------ плата-заглушка
 * Только для замера ПК на 127.0.0.1 (test_otpu_eth.py): запись памяти и чтение по
 * протоколу без проверок, память mem (каналы по chb байт подряд), пачки регистров —
 * ответ без результатов. Работает, пока *stop == 0. */
int oe_emu(int fd, uint8_t *mem, uint64_t chb, int nch, volatile int *stop)
{
    struct rxring *rx = malloc(sizeof(*rx));
    struct sockaddr_storage src[BATCH];
    static uint8_t out[BATCH][PHDR + 8192];
    struct iovec oiov[BATCH];
    struct mmsghdr omsg[BATCH];
    if (!rx)
        return -1;
    while (!*stop) {
        struct pollfd p = {.fd = fd, .events = POLLIN};
        if (poll(&p, 1, 10) <= 0)
            continue;
        for (int i = 0; i < BATCH; i++) {
            rx->iov[i].iov_base = rx->buf[i];
            rx->iov[i].iov_len = RXBUF;
            memset(&rx->msg[i].msg_hdr, 0, sizeof(rx->msg[i].msg_hdr));
            rx->msg[i].msg_hdr.msg_iov = &rx->iov[i];
            rx->msg[i].msg_hdr.msg_iovlen = 1;
            rx->msg[i].msg_hdr.msg_name = &src[i];
            rx->msg[i].msg_hdr.msg_namelen = sizeof(src[i]);
        }
        int n = recvmmsg(fd, rx->msg, BATCH, MSG_DONTWAIT, NULL);
        for (int i = 0; i < n; i++) {
            uint8_t *b = rx->buf[i];
            if (rx->msg[i].msg_len < PHDR || get32(b) != MAGIC_REQ)
                continue;
            uint32_t seq = get32(b + 4), off = get32(b + 10), len = get32(b + 14);
            uint32_t aux = get32(b + 18);
            int ch = b[9] % nch, op = b[8];
            uint8_t *m = mem + (uint64_t)ch * chb;
            int k = 0;
            if (op == OP_WRITE && (uint64_t)off + len <= chb) {
                memcpy(m + off, b + PHDR, len);
                uint8_t *h = out[0];
                memcpy(h, b, PHDR);
                put32(h, MAGIC_RESP);
                h[9] = 0;
                oiov[0].iov_base = h;
                oiov[0].iov_len = PHDR;
                k = 1;
            } else if (op == OP_READ && (uint64_t)off + len <= chb) {
                uint32_t f = aux ? aux : 8192;
                for (uint32_t o = 0; o < len;) {
                    uint32_t q = len - o < f ? len - o : f;
                    uint8_t *h = out[k];
                    put32(h, MAGIC_RESP);
                    put32(h + 4, seq);
                    h[8] = OP_READ;
                    h[9] = 0;
                    put32(h + 10, off + o);
                    put32(h + 14, q);
                    put32(h + 18, off);
                    memcpy(h + PHDR, m + off + o, q);
                    oiov[k].iov_base = h;
                    oiov[k].iov_len = PHDR + q;
                    o += q;
                    if (++k == BATCH || o >= len) {
                        for (int j = 0; j < k; j++) {
                            memset(&omsg[j].msg_hdr, 0, sizeof(omsg[j].msg_hdr));
                            omsg[j].msg_hdr.msg_iov = &oiov[j];
                            omsg[j].msg_hdr.msg_iovlen = 1;
                            omsg[j].msg_hdr.msg_name = &src[i];
                            omsg[j].msg_hdr.msg_namelen = rx->msg[i].msg_hdr.msg_namelen;
                        }
                        for (int j = 0; j < k;) {
                            int s = sendmmsg(fd, omsg + j, k - j, 0);
                            if (s < 0) {
                                if (errno == EAGAIN || errno == ENOBUFS || errno == EINTR) continue;
                                break;
                            }
                            j += s;
                        }
                        k = 0;
                    }
                }
                continue;
            } else {
                uint8_t *h = out[0];
                memcpy(h, b, PHDR);
                put32(h, MAGIC_RESP);
                h[9] = 0;
                put32(h + 10, len);
                put32(h + 14, 0);
                oiov[0].iov_base = h;
                oiov[0].iov_len = PHDR;
                k = 1;
            }
            memset(&omsg[0].msg_hdr, 0, sizeof(omsg[0].msg_hdr));
            omsg[0].msg_hdr.msg_iov = &oiov[0];
            omsg[0].msg_hdr.msg_iovlen = 1;
            omsg[0].msg_hdr.msg_name = &src[i];
            omsg[0].msg_hdr.msg_namelen = rx->msg[i].msg_hdr.msg_namelen;
            sendmmsg(fd, omsg, 1, 0);
        }
    }
    free(rx);
    return 0;
}
