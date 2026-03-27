from setuptools import setup, find_packages

setup(
    name="tidelink",
    version="0.1.0",
    description="TideLink register definitions, packet helpers, and hardware drivers",
    packages=find_packages(),
    python_requires=">=3.6",
    extras_require={
        "pynq": ["pynq"],
    },
)
