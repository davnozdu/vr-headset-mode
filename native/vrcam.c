// vrcam — съёмка с камеры XREAL Eye для модуля VR Headset Mode.
//
// Камера очков не видна обычному Android: это UVC-устройство, которое
// появляется только после вендорской HID-команды активации, и работать с
// ним можно лишь из-под root. Поэтому съёмка живёт в модуле, а приложение
// получает готовый файл по пути, который само же и назвало.
//
// Диагностика сюда намеренно не перенесена — она осталась в xrprobe.
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <dirent.h>
#include <errno.h>
#include <time.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <linux/videodev2.h>

#define XREAL_HID_ID "HID_ID=0003:00003318:00000436"

// Команда активации камеры: вендорский кадр XREAL с уже посчитанной CRC.
// Содержимое одно и то же в каждом перехвате, поэтому воспроизводится
// дословно — алгоритм контрольной суммы знать не требуется.
static const unsigned char ACTIVATE[] = {
    0xfd, 0xc6, 0xe4, 0x89, 0xb8, 0x15, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0xd3, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x45, 0x10,
    0x01, 0x00
};

// Настройки подобраны прогоном по всему диапазону каждого регулятора.
#define CID_POWER_LINE 0x00980918   // 1 = 50 Гц; с завода стоит 3 при максимуме 2
#define CID_SHARPNESS  0x0098091b   // 75; на 100 ореолы и вдвое тяжелее поток
#define CID_FOCUS_ABS  0x009a090a   // 400; резкость выходит на полку с 350

#define VAL_POWER_LINE 1
#define VAL_SHARPNESS  75
#define VAL_FOCUS      400

#define WIDTH  1920
#define HEIGHT 1080

// Автоэкспозиция после старта потока едет около десяти кадров: яркость
// поднимается со 110 до 120 примерно за 0.2 с. Эти кадры нельзя пускать
// ни в фото, ни в начало ролика.
#define WARMUP_FRAMES 25

// Кадры меньше этого — служебные пустышки, они приходят и в норме.
#define MIN_FRAME_BYTES 2000

// Потолок для записи без заданной длительности. Нужен на случай, если
// вызывающий умер и файл-стоп никто не создаст: камера не должна остаться
// включённой насовсем.
#define VIDEO_MAX_SECONDS 3600

static void die(const char *msg) {
    fprintf(stderr, "vrcam: %s\n", msg);
    exit(1);
}

/** Найти hidraw вендорского интерфейса очков (тот, что на input0). */
static int find_hidraw(char *out, size_t n) {
    DIR *d = opendir("/sys/class/hidraw");
    if (!d) return -1;
    struct dirent *e;
    int found = -1;
    while ((e = readdir(d))) {
        if (strncmp(e->d_name, "hidraw", 6) != 0) continue;
        char path[256], buf[1024];
        snprintf(path, sizeof path, "/sys/class/hidraw/%s/device/uevent", e->d_name);
        int fd = open(path, O_RDONLY);
        if (fd < 0) continue;
        ssize_t r = read(fd, buf, sizeof buf - 1);
        close(fd);
        if (r <= 0) continue;
        buf[r] = 0;
        if (!strstr(buf, XREAL_HID_ID)) continue;
        if (!strstr(buf, "input0")) continue;
        snprintf(out, n, "/dev/%s", e->d_name);
        found = 0;
        break;
    }
    closedir(d);
    return found;
}

/**
 * Найти видеоузел камеры очков.
 *
 * Номер узла не постоянен: он зависит от того, сколько камер уже есть в
 * системе и переживал ли телефон переподключение. Поэтому ищем по имени
 * драйвера и карты, а не по /dev/video2.
 */
static int find_video(char *out, size_t n) {
    for (int i = 0; i < 64; i++) {
        char path[64];
        snprintf(path, sizeof path, "/dev/video%d", i);
        int fd = open(path, O_RDWR | O_NONBLOCK);
        if (fd < 0) continue;
        struct v4l2_capability cap;
        memset(&cap, 0, sizeof cap);
        int rc = ioctl(fd, VIDIOC_QUERYCAP, &cap);
        close(fd);
        if (rc != 0) continue;
        if (strstr((char *)cap.card, "XREAL")) {
            snprintf(out, n, "%s", path);
            return 0;
        }
    }
    return -1;
}

/** Послать активацию. Ответ не обязателен: очки подтверждают не всегда. */
static int activate(void) {
    char hid[64];
    if (find_hidraw(hid, sizeof hid) != 0) return -1;
    int fd = open(hid, O_RDWR | O_NONBLOCK);
    if (fd < 0) return -1;
    ssize_t w = write(fd, ACTIVATE, sizeof ACTIVATE);
    close(fd);
    return w == (ssize_t)sizeof ACTIVATE ? 0 : -1;
}

static int set_ctrl(int fd, unsigned int id, int value) {
    struct v4l2_control c;
    memset(&c, 0, sizeof c);
    c.id = id;
    c.value = value;
    return ioctl(fd, VIDIOC_S_CTRL, &c);
}

struct cam {
    int fd;
    void *bufs[6];
    unsigned int lens[6];
    unsigned int count;
};

/**
 * Открыть камеру и запустить поток.
 *
 * O_NONBLOCK обязателен: с блокирующим дескриптором VIDIOC_DQBUF виснет
 * в ядре навсегда, если кадры перестали приходить, и цикл повторов по
 * EAGAIN не срабатывает вообще.
 */
static int cam_start(struct cam *c, const char *dev, unsigned int fourcc) {
    memset(c, 0, sizeof *c);
    c->fd = open(dev, O_RDWR | O_NONBLOCK);
    if (c->fd < 0) return -1;

    // Регуляторы ставятся тем же дескриптором: отдельный вызов открывал бы
    // устройство заново, а лишние открытия потоку не на пользу.
    set_ctrl(c->fd, CID_POWER_LINE, VAL_POWER_LINE);
    set_ctrl(c->fd, CID_SHARPNESS, VAL_SHARPNESS);
    set_ctrl(c->fd, CID_FOCUS_ABS, VAL_FOCUS);

    struct v4l2_format f;
    memset(&f, 0, sizeof f);
    f.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
    f.fmt.pix.width = WIDTH;
    f.fmt.pix.height = HEIGHT;
    f.fmt.pix.pixelformat = fourcc;
    f.fmt.pix.field = V4L2_FIELD_NONE;
    if (ioctl(c->fd, VIDIOC_S_FMT, &f) != 0) { close(c->fd); c->fd = -1; return -2; }
    if (f.fmt.pix.pixelformat != fourcc) { close(c->fd); c->fd = -1; return -3; }

    struct v4l2_requestbuffers rb;
    memset(&rb, 0, sizeof rb);
    rb.count = 6;
    rb.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
    rb.memory = V4L2_MEMORY_MMAP;
    if (ioctl(c->fd, VIDIOC_REQBUFS, &rb) != 0) { close(c->fd); c->fd = -1; return -1; }
    c->count = rb.count > 6 ? 6 : rb.count;

    for (unsigned i = 0; i < c->count; i++) {
        struct v4l2_buffer bf;
        memset(&bf, 0, sizeof bf);
        bf.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
        bf.memory = V4L2_MEMORY_MMAP;
        bf.index = i;
        if (ioctl(c->fd, VIDIOC_QUERYBUF, &bf) != 0) { close(c->fd); c->fd = -1; return -1; }
        c->bufs[i] = mmap(NULL, bf.length, PROT_READ | PROT_WRITE, MAP_SHARED, c->fd, bf.m.offset);
        c->lens[i] = bf.length;
        if (c->bufs[i] == MAP_FAILED) { close(c->fd); c->fd = -1; return -1; }
        ioctl(c->fd, VIDIOC_QBUF, &bf);
    }
    int type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
    if (ioctl(c->fd, VIDIOC_STREAMON, &type) != 0) { close(c->fd); c->fd = -1; return -1; }
    return 0;
}

static void cam_stop(struct cam *c) {
    if (c->fd < 0) return;
    int type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
    ioctl(c->fd, VIDIOC_STREAMOFF, &type);
    for (unsigned i = 0; i < c->count; i++) munmap(c->bufs[i], c->lens[i]);
    close(c->fd);
    c->fd = -1;
}

/**
 * Снять один кадр.
 *
 * Ждать кадр нужно щедро: первый содержательный камера отдаёт позже чем
 * через полсекунды, и слишком короткий таймаут даёт «ноль кадров» на
 * заведомо рабочем потоке. Возвращает индекс буфера, размер — в *len.
 */
static int cam_frame(struct cam *c, struct v4l2_buffer *bf) {
    memset(bf, 0, sizeof *bf);
    bf->type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
    bf->memory = V4L2_MEMORY_MMAP;
    for (int a = 0; a < 60; a++) {
        if (ioctl(c->fd, VIDIOC_DQBUF, bf) == 0) return 0;
        if (errno != EAGAIN) return -1;
        usleep(20000);
    }
    return -1;
}

/**
 * Разобрать типы NAL-единиц в кадре Annex-B.
 *
 * Нужно ровно две вещи: несёт ли кадр наборы параметров (VPS/SPS/PPS) и
 * опорный ли он. Камера отдаёт заголовки не в начале потока, а вместе с
 * каждым опорным кадром, поэтому запись обязана начинаться именно с
 * такого — иначе первые кадры ссылаются на параметры, которых в файле нет,
 * и декодер спотыкается на «PPS id out of range».
 */
static void scan_nals(const unsigned char *p, unsigned int len,
                      int *has_params, int *is_key) {
    *has_params = 0;
    *is_key = 0;
    for (unsigned int i = 0; i + 4 < len; ) {
        int sl;
        if (p[i] == 0 && p[i+1] == 0 && p[i+2] == 0 && p[i+3] == 1) sl = 4;
        else if (p[i] == 0 && p[i+1] == 0 && p[i+2] == 1) sl = 3;
        else { i++; continue; }
        int type = (p[i + sl] >> 1) & 0x3F;
        if (type == 32) *has_params = 1;          // VPS
        if (type >= 16 && type <= 21) *is_key = 1; // IDR/CRA и соседи
        i += sl;
    }
}

/** Пропустить n содержательных кадров: настройки вступают в силу не сразу. */
static int cam_warmup(struct cam *c, int n) {
    int seen = 0;
    for (int i = 0; i < n + 60; i++) {
        struct v4l2_buffer bf;
        if (cam_frame(c, &bf) != 0) return -1;
        if (bf.bytesused > MIN_FRAME_BYTES) seen++;
        ioctl(c->fd, VIDIOC_QBUF, &bf);
        if (seen >= n) return 0;
    }
    return -1;
}

/**
 * Фото: берём самый тяжёлый кадр из серии.
 *
 * При одинаковых настройках вес растёт вместе с детализацией, а смазанный
 * кадр весит меньше — так что самый крупный из серии обычно и самый резкий.
 */
static int shoot_photo(const char *dev, const char *out) {
    struct cam c;
    int rc = cam_start(&c, dev, V4L2_PIX_FMT_MJPEG);
    if (rc != 0) return rc;
    if (cam_warmup(&c, WARMUP_FRAMES) != 0) { cam_stop(&c); return -1; }

    unsigned int best = 0;
    for (int i = 0; i < 40; i++) {
        struct v4l2_buffer bf;
        if (cam_frame(&c, &bf) != 0) break;
        if (bf.bytesused > best) {
            best = bf.bytesused;
            FILE *f = fopen(out, "wb");
            if (f) { fwrite(c.bufs[bf.index], 1, best, f); fclose(f); }
        }
        ioctl(c.fd, VIDIOC_QBUF, &bf);
    }
    cam_stop(&c);
    if (best == 0) return -1;
    printf("%s %u\n", out, best);
    return 0;
}

/**
 * Видео: поток HEVC кладём в файл как есть, кадр за кадром, и рядом — индекс.
 *
 * Контейнер здесь не делается намеренно: это задача приложения, у него для
 * этого есть MediaMuxer. HEVC выбран как раз потому, что MediaMuxer умеет
 * паковать его в MP4 напрямую, а MJPEG не умеет вовсе.
 *
 * Индекс (<файл>.idx, по строке на кадр: смещение, размер, метка в мкс)
 * нужен для двух вещей сразу. Во-первых, MediaMuxer принимает кадры
 * поштучно, а в склеенном потоке их границы пришлось бы искать разбором
 * NAL-единиц. Во-вторых, метки V4L2 идут по CLOCK_MONOTONIC — в той же
 * шкале, что и AudioRecord.getTimestamp, — поэтому по ним звук сводится с
 * картинкой по общим часам, а не встык. Без этого звук уезжал бы вперёд на
 * время прогрева автоэкспозиции.
 */
/**
 * Запись идёт, пока не появится файл-стоп рядом с выходным.
 *
 * Останавливать сигналом было бы неудобно вызывающему: приложение держит
 * единственный root-шелл занятым на всё время съёмки и вторую команду
 * послать не может. Файл же оно создаёт само, без root и без шелла.
 */
static int stop_requested(const char *out) {
    char p[512];
    snprintf(p, sizeof p, "%s.stop", out);
    return access(p, F_OK) == 0;
}

/**
 * @param seconds сколько писать; 0 или меньше — до файла-стопа.
 */
static int shoot_video(const char *dev, const char *out, int seconds) {
    struct cam c;
    int rc = cam_start(&c, dev, v4l2_fourcc('H', 'E', 'V', 'C'));
    if (rc != 0) return rc;
    if (cam_warmup(&c, WARMUP_FRAMES) != 0) { cam_stop(&c); return -1; }

    FILE *f = fopen(out, "wb");
    if (!f) { cam_stop(&c); return -1; }

    char idxpath[512];
    snprintf(idxpath, sizeof idxpath, "%s.idx", out);
    FILE *idx = fopen(idxpath, "w");
    if (!idx) { fclose(f); cam_stop(&c); return -1; }

    time_t t0 = time(NULL);
    unsigned long total = 0;
    long long first_us = 0;
    int frames = 0, stalls = 0, started = 0;
    // Без заданной длительности пишем до остановки, но не вечно: зависший
    // вызывающий не должен оставить камеру включённой на всю ночь.
    int limit = seconds > 0 ? seconds : VIDEO_MAX_SECONDS;
    int wait_stop = seconds <= 0;
    while (time(NULL) - t0 < limit) {
        if (wait_stop && stop_requested(out)) break;
        struct v4l2_buffer bf;
        if (cam_frame(&c, &bf) != 0) {
            // Одиночный таймаут — не повод бросать запись: поток мог
            // запнуться на кадре. Сдаёмся, только если тишина подряд.
            if (++stalls >= 3) break;
            continue;
        }
        stalls = 0;
        if (bf.bytesused > MIN_FRAME_BYTES) {
            const unsigned char *data = c.bufs[bf.index];
            int has_params, is_key;
            scan_nals(data, bf.bytesused, &has_params, &is_key);

            // Первым в файл обязан лечь кадр с наборами параметров: камера
            // включается посреди группы, и без заголовков начало потока
            // декодировать нечем. Ждём опорный — это до полусекунды.
            if (!started && has_params) started = 1;

            if (started) {
                long long us = (long long)bf.timestamp.tv_sec * 1000000 + bf.timestamp.tv_usec;
                if (frames == 0) first_us = us;
                fprintf(idx, "%lu %u %lld %d\n", total, bf.bytesused, us, is_key ? 1 : 0);
                fwrite(data, 1, bf.bytesused, f);
                total += bf.bytesused;
                frames++;
            }
        }
        ioctl(c.fd, VIDIOC_QBUF, &bf);
    }
    fclose(idx);
    fclose(f);
    // Убираем за собой: оставленный файл-стоп оборвал бы следующую запись
    // в первую же секунду.
    {
        char sp[512];
        snprintf(sp, sizeof sp, "%s.stop", out);
        unlink(sp);
    }
    int secs = (int)(time(NULL) - t0);
    cam_stop(&c);
    if (frames == 0) return -1;
    // Метка первого кадра — якорь, по которому приложение подрежет звук.
    printf("%s %lu %d %.2f %lld\n", out, total, frames,
           secs > 0 ? (double)frames / secs : 0.0, first_us);
    return 0;
}

static void usage(void) {
    printf("использование:\n"
           "  vrcam status\n"
           "  vrcam photo <файл>\n"
           "  vrcam video <файл> [секунд]   без секунд — до файла <файл>.stop\n");
}

int main(int argc, char **argv) {
    if (argc < 2) { usage(); return 2; }

    char dev[64];
    int have = find_video(dev, sizeof dev) == 0;
    if (!have) {
        // Камеры ещё нет — поднимаем её и ждём появления узла.
        if (activate() != 0) {
            fprintf(stderr, "vrcam: очки не найдены\n");
            return 3;
        }
        for (int i = 0; i < 40 && !have; i++) {
            usleep(250000);
            have = find_video(dev, sizeof dev) == 0;
        }
        if (!have) { fprintf(stderr, "vrcam: камера не поднялась\n"); return 3; }
        // Узел появляется раньше, чем камера готова отдавать кадры.
        sleep(2);
    }

    if (!strcmp(argv[1], "status")) {
        printf("%s\n", dev);
        return 0;
    }
    if (!strcmp(argv[1], "photo") && argc > 2) {
        int rc = shoot_photo(dev, argv[2]);
        if (rc == -2) die("поток не взведён — переподключите очки");
        if (rc != 0) die("снять кадр не удалось");
        return 0;
    }
    if (!strcmp(argv[1], "video") && argc > 2) {
        // Без длительности пишем до появления файла-стопа.
        int secs = argc > 3 ? atoi(argv[3]) : 0;
        int rc = shoot_video(dev, argv[2], secs);
        if (rc == -2) die("поток не взведён — переподключите очки");
        if (rc == -3) die("режим HEVC не встал");
        if (rc != 0) die("записать видео не удалось");
        return 0;
    }
    usage();
    return 2;
}
