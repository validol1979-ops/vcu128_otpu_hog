"""Сводка итогов тестов из out/*.json (печать и out/summary.md)."""

import json
import sys
from pathlib import Path

OUT = Path(__file__).resolve().parent / "out"


def main():
    rows = ["| запуск | тест | команд чт/зп | данных чт | обгонов | ожиданий (такты) | "
            "ошибок ответа | пропускная способность |",
            "|---|---|---|---|---|---|---|---|"]
    for f in sorted(OUT.glob("*__*.json")):
        d = json.loads(f.read_text())
        tag, name = f.stem.split("__", 1)
        st = d.get("status", {})
        if "reads" in d:
            cmds = f"{sum(d['reads'])}/{sum(d['writes'])}"
            rdata = d.get("rdata", "")
        else:
            cmds = f"{d.get('n_reads', 0)}/{d.get('n_writes', 0)}"
            rdata = d.get("n_rdata", "")
            if "x" in d:
                cmds += f" + XDMA {d['x']['xw']}/{d['x']['xr']}"
        bw = ""
        if "bytes_per_cycle" in d:
            bw = f"{d['bytes_per_cycle']} Б/такт uclk ({d['gbps_225mhz']} ГБ/с)"
        elif "bytes_per_uclk" in d:
            bw = f"{d['bytes_per_uclk']} Б/такт uclk ({d['gbps']} ГБ/с)"
        elif "x_stream" in d:
            xs = d["x_stream"]
            bw = f"XDMA зп {xs['w']['gbps']} ГБ/с, чт {xs['r']['gbps']} ГБ/с"
        flag = "" if not d.get("errors") else (
            " (мутант пойман)" if tag.startswith("mutant") else " **FAIL**")
        rows.append(f"| {tag} | {name}{flag} | {cmds} | {rdata} | {d.get('overtakes', '')} | "
                    f"{sum(st.get('dep', [0]))} | {st.get('err_cnt', '')} | {bw} |")
    text = "\n".join(rows) + "\n"
    (OUT / "summary.md").write_text(text)
    sys.stdout.write(text)


if __name__ == "__main__":
    main()
