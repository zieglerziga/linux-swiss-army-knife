(() => {
  "use strict";

  const recordsElement = document.querySelector("#records");
  const summaryElement = document.querySelector("#summary");
  const updatedAtElement = document.querySelector("#updated-at");
  const statusElement = document.querySelector("#status");
  const filterElement = document.querySelector("#filter");
  let records = [];

  const value = (candidate) => candidate || "Not reported";

  const cell = (text, detail = "") => {
    const element = document.createElement("td");
    element.textContent = text;
    if (detail) {
      const note = document.createElement("small");
      note.textContent = detail;
      element.append(document.createElement("br"), note);
    }
    return element;
  };

  const renderRecords = () => {
    const filter = filterElement.value.trim().toLowerCase();
    const visible = records.filter((record) => {
      const runner = record.runner || {};
      const system = record.system || {};
      return [runner.label, runner.os, runner.architecture, system.name]
        .join(" ").toLowerCase().includes(filter);
    });

    recordsElement.replaceChildren();
    if (!visible.length) {
      const row = document.createElement("tr");
      const empty = cell("No runner labels match this filter.");
      empty.colSpan = 6;
      empty.className = "empty";
      row.append(empty);
      recordsElement.append(row);
    } else {
      visible.forEach((record) => {
        const runner = record.runner || {};
        const image = record.image || {};
        const system = record.system || {};
        const tools = record.tools || {};
        const row = document.createElement("tr");
        row.append(
          cell(value(runner.label)),
          cell(value(runner.os), value(runner.architecture)),
          cell(value(image.os), value(image.version)),
          cell(value(system.name), [system.version, system.build].filter(Boolean).join(" · ")),
          cell(value(system.kernel_name), [system.kernel_release, system.machine_architecture].filter(Boolean).join(" · ")),
          cell(value(tools.xcode_version)),
        );
        recordsElement.append(row);
      });
    }
    statusElement.textContent = `Showing ${visible.length} of ${records.length} collected runner${records.length === 1 ? "" : "s"}.`;
  };

  const renderSummary = () => {
    const platforms = new Set(records.map((record) => record.runner && record.runner.os).filter(Boolean));
    const architectures = new Set(records.map((record) => record.runner && record.runner.architecture).filter(Boolean));
    const images = new Set(records.map((record) => record.image && record.image.version).filter(Boolean));
    const metrics = [
      [records.length, "runner labels observed"],
      [platforms.size, "operating systems"],
      [architectures.size, "runner architectures"],
      [images.size, "image versions"],
    ];
    summaryElement.replaceChildren(...metrics.map(([number, label]) => {
      const card = document.createElement("div");
      card.className = "metric";
      const strong = document.createElement("strong");
      strong.textContent = number;
      const text = document.createElement("span");
      text.textContent = label;
      card.append(strong, text);
      return card;
    }));
  };

  fetch("data/runners.json", { cache: "no-store" })
    .then((response) => {
      if (!response.ok) throw new Error(`HTTP ${response.status}`);
      return response.json();
    })
    .then((dataset) => {
      if (!Array.isArray(dataset.runners)) throw new Error("dataset has no runners array");
      records = dataset.runners.sort((left, right) => left.runner.label.localeCompare(right.runner.label));
      updatedAtElement.textContent = `Generated ${value(dataset.generated_at)} from ${records.length} runner observation${records.length === 1 ? "" : "s"}.`;
      renderSummary();
      renderRecords();
    })
    .catch((error) => {
      updatedAtElement.textContent = "The latest runner dataset could not be loaded.";
      statusElement.textContent = `Data error: ${error.message}`;
    });

  filterElement.addEventListener("input", renderRecords);
})();
